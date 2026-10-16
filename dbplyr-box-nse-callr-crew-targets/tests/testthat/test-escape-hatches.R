# Guards for part 6 (06-escape-hatches.R): dbplyr options, escape hatches, check_ambiguity().
library(dplyr)
library(dbplyr)
source(test_path("../../R/check_ambiguity.R"))

df <- tibble::tibble(var1 = c(1, 2, 3), name = c("alpha", "beta", "gamma"))
lazy <- \(x = df) copy_to(memdb(), x, name = basename(tempfile("t")))
col <- \(x) collect(x)$x
lst <- list(f = \(x) x * 2)
f_expr <- \(x) rlang::expr(!!rlang::enexpr(x) * 2)   # helper that returns code, spliced with !!

test_that("dplyr.strict_sql = TRUE: unknown functions fail at render, .sql$ too; sql() still works", {
  withr::local_options(dplyr.strict_sql = TRUE)
  d <- lazy()
  expect_error(sql_render(mutate(d, x = foo(var1))), "Don't know how to translate `foo\\(\\)`")
  expect_error(sql_render(mutate(d, x = .sql$instr(name, "a"))), "Don't know how to translate `instr\\(\\)`")
  expect_equal(col(mutate(d, x = sql("instr(name, 'a')"))), c(1, 4, 2))
  var1 <- 100
  expect_equal(col(mutate(d, x = lst$f(var1))), rep(200, 3))   # strict mode does NOT catch the local-eval bug
})

test_that("without strict, .sql$fn and unknown fn pass through to SQL", {
  expect_equal(col(mutate(lazy(), x = .sql$instr(name, "a"))), c(1, 4, 2))
  expect_error(collect(mutate(lazy(), x = foo(var1))), "foo")
})

test_that("local() / remote() are dbplyr special forms; .local does not exist", {
  var1 <- 100
  expect_equal(col(mutate(lazy(), x = local(var1))), rep(100, 3))   # dbplyr: evaluate in R env
  expect_equal(col(mutate(df, x = local(var1))), c(1, 2, 3))        # base::local() on a tibble sees the column!
  expect_equal(col(mutate(lazy(), x = remote(var1) * 2)), c(2, 4, 6))
  expect_error(mutate(df, x = remote(var1)), "remote")
  expect_false(any(purrr::map_lgl(c("rlang", "dplyr", "dbplyr", "tidyselect"), \(p) exists(".local", asNamespace(p), inherits = FALSE))))
  expect_error(mutate(lazy(), x = .local$var1), ".local")
})

test_that("lst$f(col) on a DB: none of the wrappers fix it; code-returning helpers / collect() do", {
  var1 <- 100
  expect_equal(col(mutate(lazy(), x = local(lst$f(var1)))), rep(200, 3))
  expect_equal(col(mutate(lazy(), x = (!!lst$f)(var1))), rep(200, 3))
  expect_error(mutate(lazy(), x = lst$f(.data$var1)), "outside of a data mask")
  for (d in list(df, lazy())) expect_equal(col(mutate(d, x = !!f_expr(var1))), c(2, 4, 6))
  expect_equal(lazy() |> collect() |> mutate(x = lst$f(var1)) |> col(), c(2, 4, 6))
})

test_that("sql_glue2(): escaped identifiers and values, spliced with !!", {
  d <- lazy(); con <- remote_con(d); colname <- "var1"; k <- 2; bad <- "alpha' OR '1'='1"
  expect_equal(col(mutate(d, x = !!sql_glue2(con, "{.id colname} * {k}"))), c(2, 4, 6))
  expect_equal(nrow(collect(filter(d, name == !!sql_glue2(con, "{bad}")))), 0)
})

test_that("dplyr/dbplyr and lintr say nothing about a column + variable clash", {
  withr::local_options(lifecycle_verbosity = "warning", rlib_warning_verbosity = "verbose")
  var1 <- 100
  for (d in list(df, lazy())) expect_no_warning(collect(mutate(d, x = var1)))
  skip_if_not_installed("lintr")
  code <- "f <- function(d) { var1 <- 100; dplyr::mutate(d, x = var1) }\ng <- function(d) dplyr::mutate(d, x = var1)\n"
  l <- as.data.frame(lintr::lint(text = code, linters = lintr::object_usage_linter()))
  expect_equal(l$line_number, 2L)   # flags the CORRECT column use (g), not the ambiguous f
})

test_that("check_ambiguity() warns on bare names that are both a column and an object", {
  var1 <- 100
  for (d in list(df, lazy())) {
    expect_warning(check_ambiguity(d, x = var1), class = "ambiguous_name")
    expect_no_warning(check_ambiguity(d, x = .data$var1, y = .env$var1, z = !!var1, w = .data[["var1"]]))
    expect_no_warning(check_ambiguity(d, across(c(var1), \(v) v * 2), .by = var1))   # tidyselect args skipped
  }
  expect_warning(check_ambiguity(lazy(), x = lst$f(var1)), "OBJECT")
  wrap <- \(d, v) check_ambiguity(d, x = {{ v }})   # defined outside expect_*(): testthat itself processes {{ }} / !!
  expect_warning(wrap(df, var1), class = "ambiguous_name")
  expect_error(check_ambiguity(df, x = var1, .error = TRUE), class = "ambiguous_name")
})

test_that("check_ambiguity(): scope rules and known false positives", {
  expect_no_warning(check_ambiguity(df, x = var1))                    # no object var1 here
  name <- function() "fn"; expect_no_warning(check_ambiguity(df, x = name))   # functions ignored
  y <- 5; expect_warning(check_ambiguity(df, y = 1, z = y), "`y`")    # earlier new column counts
  expect_warning(check_ambiguity(tibble::tibble(pi = 1, r = 2), a = pi * r^2), "`pi`")   # base constant: real trap
  var1 <- 100
  expect_warning(check_ambiguity(df, x = !!rlang::sym("var1")), class = "ambiguous_name")  # false positive
})

test_that("checked verbs give the same result as dplyr verbs", {
  var1 <- 100
  d <- lazy()
  expect_equal(suppressWarnings(collect(mutate_chk(d, x = var1 * 2))), collect(mutate(d, x = var1 * 2)))
  expect_equal(collect(filter_chk(d, .data$var1 > 1)), collect(filter(d, var1 > 1)))
  expect_equal(collect(summarise_chk(d, m = sum(.data$var1, na.rm = TRUE))), collect(summarise(d, m = sum(var1, na.rm = TRUE))))
})

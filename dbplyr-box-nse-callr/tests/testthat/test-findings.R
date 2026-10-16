# Regression guards for the behaviours documented in README.md.
# If a package upgrade changes one of these, the README needs updating.
library(dplyr)
library(dbplyr)

df <- tibble::tibble(var1 = c(1, 2, 3), name = c("a", "b", "c"))
lazy <- \() copy_to(memdb(), df, name = paste0("df_", sample.int(1e9, 1)))
col <- \(x) collect(x)$x

test_that("column beats global of the same name; .env$ / !! reach the global", {
  var1 <- 100
  for (d in list(df, lazy())) {
    expect_equal(col(mutate(d, x = var1)), c(1, 2, 3))
    expect_equal(col(mutate(d, x = .env$var1)), rep(100, 3))
    expect_equal(col(mutate(d, x = !!var1)), rep(100, 3))
  }
})

test_that("dbplyr: unknown function is passed to SQL and fails at execute, not build", {
  d <- mutate(lazy(), x = foo(var1))
  expect_no_error(sql_render(d))
  expect_error(collect(d), "foo")
})

test_that("dbplyr: non-symbol call head (lst$f(col)) is evaluated LOCALLY -> silently wrong", {
  var1 <- 100; lst <- list(f = \(x) x * 2)
  expect_equal(col(mutate(df, x = lst$f(var1))), c(2, 4, 6))        # tibble: correct
  expect_equal(col(mutate(lazy(), x = lst$f(var1))), rep(200, 3))   # dbplyr: global var1 used, not the column
})

test_that("dbplyr: no 'strict' options exist in this version", {
  src <- unlist(lapply(ls(asNamespace("dbplyr"), all.names = TRUE), \(f) {
    x <- get(f, asNamespace("dbplyr")); if (is.function(x)) deparse(x)
  }))
  expect_false(any(grepl("getOption\\(\"dbplyr\\.", src)))
})

test_that("callr child is a clean session: no globals, no attached packages", {
  only_global <- 5
  expect_error(callr::r(\() only_global), "only_global")
  expect_error(callr::r(\(d) mutate(d, x = 1), args = list(df)), "mutate")
  expect_equal(callr::r(\(g) g, args = list(only_global)), 5)
})

test_that("callr: DB connection / lazy table cannot cross the process boundary", {
  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE)); on.exit(DBI::dbDisconnect(con))
  expect_error(callr::r(\(con) DBI::dbGetQuery(con, "select 1"), args = list(con)), "Invalid connection")
})

test_that("box: module functions do not see the caller's globals", {
  skip_if_not_installed("box")
  res <- callr::r(\(wd) {
    options(box.path = wd); box::use(mods/helpers)
    only_global <- 5
    try(helpers$add_global_only(data.frame(var1 = 1)), silent = TRUE) |> class()
  }, args = list(normalizePath(file.path(testthat::test_path(), "../..")))
  )
  expect_equal(res, "try-error")
})

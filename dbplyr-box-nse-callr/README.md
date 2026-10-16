# dbplyr × box × NSE × callr/crew — what actually happens

Answers issue #1. Everything here is reproducible: each part is a script that writes a CSV to `results/`;
`build-report.R` turns those into `results/tables.md` (full per-case tables, all three backends) and `results/versions.md`.

| file | what |
|---|---|
| `01-nse.R` | column vs. global vs. function-local, `.data`/`.env`/`!!`/`{{ }}`, tidyselect, unknown fns — on **tibble, duckdb, sqlite** |
| `02-box.R` + `mods/helpers.R` | box module scoping, aliasing, `ns$fn` vs `pkg::fn`, translation of box-imported fns |
| `03-callr-crew.R` | fresh R sessions: globals, `library()`, `box::use()`, `box.path`, DB connections |
| `tests/testthat/test-findings.R` | 16 fast regression guards for the findings below (run `testthat::test_dir("tests/testthat")` from this dir) |
| `results/*.csv`, `results/tables.md` | raw captures: outcome, **where it failed** (`build`/`render`/`execute`), value, SQL, warnings, messages |

Run: `Rscript 01-nse.R; Rscript 02-box.R; Rscript 03-callr-crew.R; Rscript build-report.R` (from this directory; ~1 min).

## Versions used (all current on the CRAN mirror at test time, 2026-10-16)

R 4.6.1 · dplyr 1.2.1 · dbplyr 2.6.0 · DBI 1.3.0 · duckdb 1.5.6 · RSQLite 3.53.3 · box 1.2.3 · callr 3.8.0 · crew 1.3.3 · mirai 2.7.3 · tidyselect 1.2.1 · rlang 1.3.0.
Full table with "newer available?": `results/versions.md`. Backends were duckdb + SQLite only — **no Oracle/MSSQL** (not available here), so translation/quoting conclusions are for those two dialects.

---

## 1. NSE: who wins, column or global?

**Rule (identical on tibble and dbplyr): column > anything in the calling env.** Global is only used if no column has that name.

| situation | result |
|---|---|
| `mutate(x = var1)`, `var1` is col **and** global | column (1,2,3) |
| global only | global value, inlined as a literal (`SELECT *, 5.0 AS x`) |
| neither | **build-time** error (dbplyr wording: `Object 'x' not found.`) |
| `.env$var1` / `!!var1` | global (100) — the two safe ways to say "I mean the variable" |
| `.data$var1` | column |
| `.data$missing` | tibble: build error · **dbplyr: passes through to SQL → fails at `collect()`** with the DB's own binder error |
| function arg named like a column (`\(d, var1) mutate(d, x = var1)`) | **column wins, arg ignored** — the classic footgun. Use `{{ }}`, `.env$`, or don't name args like columns |
| function-local var, no column of that name | works |
| `filter(var1 == var1)` | tautology (keeps everything), no warning |
| string var as column name | `.data[[colname]]` or `!!sym(colname)`; bare `colname` is just the string |

Extra dbplyr-vs-dplyr differences found (all silent unless noted):
- **Global vector length > 1 as a value**: tibble recycles/errors on size; dbplyr inlines a SQL **tuple** `(10.0, 20.0, 30.0)` → duckdb returns a weird per-row struct/list column, **sqlite errors** (`row value misused`). Length 2 on 3 rows: tibble errors, duckdb "works". Use `%in%` for membership.
- `filter(var1 == na_global)` → SQL `= NULL` → **0 rows, no warning** (same as R's `NA` logic, but easy to miss). Use `is.na()`.
- `mutate(x = NULL_global)` is silently a no-op on both.
- `Sys.Date()` in `filter()`: tibble fine; dbplyr passes it through as an SQL function → **fails on execute** (duckdb/sqlite). Compute outside: `!!Sys.Date()`.
- `select(chr_global)` (external character vector, no `all_of`): tibble gives the tidyselect deprecation **warning**; on dbplyr **no warning at all** (still works). Always `all_of()`/`any_of()`.
- `select(any_of("nope"))`: tibble returns 0-col tibble; dbplyr errors at **render** ("Query contains no columns").
- SQLite has no date type: `copy_to` stores `Date` as a number, so date filters/printing/`year()` behave differently from duckdb (`year(dt)` = `-4659`!). Not a dbplyr bug, but don't test date logic on SQLite.

### Unknown / untranslatable functions (dbplyr)

- **Unknown function names are passed verbatim to SQL** (`foo(var1)` → `FOO(var1)`), so the error appears at **execute** with the DB's message, not at build. That's by design, and also why `Sys.Date()`, `myfun(col)`, `rev(col)` all fail only on `collect()`.
- To call a real SQL function on purpose: `.sql$abs(var1)` (new in 2.6.0; errors on a plain tibble, as it should) or `sql("ABS(var1)")`. Both work on duckdb and sqlite.
- Package-qualified calls `stringr::str_to_upper(col)` **are** translated (it strips the `pkg::`). Same for `lubridate::year`.
- **dbplyr has no "strict" options in 2.6.0.** I searched the whole namespace for `getOption("dbplyr.*")`: none (guarded by a test). What exists instead: `last_sql()` / `show_query()` / `sql_render()` to inspect, `.sql$` / `sql()` as the explicit escape hatch, `sql_options()` (cte / star / qualify) which changes *rendering*, not strictness. If you want "error on unknown function", that's an upstream feature request (see §5).

### ⚠️ Silent wrong result (most important finding)

dbplyr's `partial_eval` evaluates any call whose **function is not a plain symbol** *locally* — `lst$f(col)`, `pkg$fn(col)`, `(\(z) z*2)(col)` — and resolves `col` from the **calling env, not the column**:

```r
var1 <- 100; lst <- list(f = \(x) x * 2); d <- memdb_frame(var1 = 1:3)
d |> mutate(x = lst$f(var1)) |> show_query()
#> SELECT *, 200.0 AS `x`        <- global var1 (100) * 2, not the column
d |> mutate(x = lst$f(var1)) |> collect()   # x = 200, 200, 200   (tibble gives 2, 4, 6)
rm(var1)                                     # now: "Caused by error: ! object 'var1' not found"
```

No warning or message. Hits box users directly because box encourages `helpers$double_it(col)` (see §2). Reproduced in `test-findings.R`.

## 2. box

| situation | result |
|---|---|
| module fn referencing a **global** (`only_global`) | not visible: `object not found` — module scope's parent is box's namespace/base, never `.GlobalEnv`. Good (reproducible), but means module fns can't rely on globals |
| module-level object with same name as column (`var1 <- 999` in module, col `var1`) | column still wins (1,2,3) |
| module-level object, no column | used (42) |
| `.env$var1` inside module fn | the **module's** `var1` (999), not global's |
| `dplyr$summarise(d, x = dplyr$n())` | tibble ✅, dbplyr ❌ "Must only be used inside data-masking" — `ns$fn` form isn't translated; use `box::use(dplyr[n])` + `n()` or `dplyr::n()` |
| `lubridate$year(dt)` | tibble ✅, dbplyr ❌ build error (local eval, see §1). `lubridate::year(dt)` ✅ translated. |
| module fn `helpers$double_it(col)` *inside the query* | tibble ✅ · **dbplyr: silent wrong value** (200,200,200 — the §1 bug) |
| module fn `double_it(col)` called as a bare symbol inside a module query | tibble ✅ · dbplyr ❌ execute: `no such function: double_it` (passed to SQL) |
| aliased import (`box::use(stringr[nch = str_length])`, `nch(name)`) | tibble ✅ · dbplyr ❌ execute: `no such function: nch`. **dbplyr translates by call name, not by function identity** — aliasing a translatable fn breaks translation. Aliasing *verbs* (`mutate_alias`) is fine (S3 dispatch on the object) |
| `box::use(stringr[str_to_upper])` then `str_to_upper(col)` | ✅ everywhere (name-based) |
| attaching style (`box::use(dplyr[mutate])`) inside a function | ✅ |
| `box::use(base[nchar])` | ❌ **box 1.2.3 on R 4.6.1**: `no item called "getNamespaceInfo(mod_ns, "lazydata")" on the search list` (works for every other pkg I tried). Candidate upstream bug, §5 |

Takeaway: box scoping is *stricter* than `library()` (nothing leaks from global), which is great for reproducibility, and dbplyr is *name-based*, so import names matter more than import mechanics. Keep SQL-translatable calls as bare names or `pkg::fn`; never wrap them in `mod$fn(col)`.

## 3. callr / crew

Both start **fresh R sessions**: nothing from your global env, no attached packages, no options.

| case | callr | crew (mirai worker) |
|---|---|---|
| `mutate()` w/o `library(dplyr)` | ❌ `could not find function "mutate"` | ❌ same; fix with `packages = "dplyr"` ✅ |
| `dplyr::mutate()` | ✅ | ✅ |
| fn/command referencing a global | ❌ `object not found` — even though the closure's env is `.GlobalEnv` (global is referenced, not serialised) | ❌ same; pass via `data = list(...)` ✅ |
| var captured from a *local* function scope | ❌ `object 'loc' not found` (the function is shipped, its enclosing scope's variables are not) | n/a |
| global helper fn | ❌ `could not find function` | n/a |
| `box::use(dplyr[mutate])` inside the fn/command | ✅ (box needs no `library()`) | ✅ |
| `box::use(mods/helpers)` (relative module) | ❌ `unable to load module "mods/helpers"; not found in ".../box/mod", "/tmp/Rtmp…"` — child doesn't have your `box.path` and relative lookup is anchored to a temp dir | ✅ (worker cwd = parent cwd; box finds it) |
| …after `options(box.path = p)` in the child | ✅ | ✅ |
| `getOption("box.path")` in child/worker | `NULL` — **options are not inherited** | `NULL` at first, but **persists** once any task set it → **state leaks between tasks** on a long-lived worker |
| module function passed as an argument | ✅ works (module env serialises fine; imports come along) | ✅ |
| a module function as the callr function itself | ✅ | n/a |
| duckdb connection / lazy `tbl()` passed to child | ❌ `Invalid connection` (external pointer); `collect()` on a lazy tbl also fails with `no applicable method` because the child hasn't loaded dbplyr/duckdb | ❌ same class of error |
| child opens its own connection | ✅ | ✅ (not run, same mechanism) |
| cwd, `.libPaths()` | inherited ✅ | cwd inherited ✅ |

So: **box does work in callr/crew** — it's `library()`-free by design, which is *better* than the attach-dependent style. The only trap is **module path resolution** (`box.path` isn't inherited; relative lookup differs between callr and crew), plus the usual "fresh session" rules: pass data in, pass **connection details** (not connections), declare packages.

## 4. Mistake-avoidance cheat sheet (also: paste to your LLM)

```
R / tidyverse / dbplyr / box / callr rules (verified on dplyr 1.2.1, dbplyr 2.6.0, box 1.2.3, callr 3.8.0, crew 1.3.3):
1. In dplyr/dbplyr verbs a COLUMN always beats a same-named variable. Never name a function argument like a column.
   Use .env$x or !!x for variables, .data$col or .data[[chr]] for columns, {{ arg }} for forwarded column args.
2. dbplyr passes unknown function names straight to SQL; the error appears at collect(), not at the verb. Use
   show_query() / last_sql() while developing. Escape hatch for real SQL functions: .sql$fn(col) or sql("...").
3. dbplyr translates by call NAME. pkg::fn(col) is OK; bare imported fn(col) is OK; ALIASED imports (nch = str_length)
   and mod$fn(col) / ns$fn(col) are NOT translated. mod$fn(col) / lst$f(col) / (\(x) ..)(col) are evaluated LOCALLY and
   can silently use a same-named GLOBAL instead of the column. Compute locals outside the query and splice with !!.
4. Do not use Sys.Date(), R-only fns, or globals of length > 1 inside dbplyr queries; use !!Sys.Date(), is.na(), %in%.
   Always all_of()/any_of() for character vectors of column names.
5. box modules never see .GlobalEnv. Pass everything as arguments. Don't aliases-import translatable functions.
6. callr / crew workers are fresh R sessions: no globals, no packages attached, no options (box.path!), DB connections
   cannot be sent. Pass data via args / data=, declare packages= (or use pkg:: / box::use inside), set options(box.path)
   inside the task, open DB connections inside the task. crew workers are long-lived: options set in one task leak to the next.
7. SQLite is a poor stand-in for testing date logic (no date type). Test on duckdb or the real dialect.
```

## 5. Candidates for upstream issues/PRs (drafted, **not filed** — your call)

1. **dbplyr — silent wrong result for non-symbol call heads** (§1 reprex above). Ask: either evaluate such calls with the data mask (so `col` resolves to the column) or warn/error when a locally-evaluated call references a column name that also exists in the env. This is the highest-value one. *(Check existing issues first — I could only reach this repo, so I haven't searched dbplyr's tracker.)*
2. **dbplyr — optional strictness**: an option/arg to error at build time on untranslatable functions (the issue's "strict" idea doesn't exist today); and a warning when `partial_eval` inlines a global vector of length > 1 as a tuple.
3. **box — `box::use(base[...])` fails on R 4.6.1** with `getNamespaceInfo(mod_ns, "lazydata")` error. Minimal reprex: `Rscript -e 'box::use(base[nchar])'`.
4. **dbplyr docs/message**: unknown-function passthrough is documented, but the `collect()` error doesn't hint "this function wasn't translated; use `.sql$`" — possible message improvement (error currently shows only the DB's catalog error).
5. **tidyselect** (minor): external-vector-in-`select()` deprecation warning is not emitted for lazy tables.

## Caveats / what I did not test

- Only duckdb and SQLite; the Oracle/MSSQL dialects have different translations (and quoting) — worth re-running part 1 against your Oracle/MSSQL with the same scripts (swap `setup_backends()`).
- `dbplyr` options like `qualify_all_columns`/`cte` change SQL, not NSE; not permuted.
- crew was tested with one local worker; `targets`/`future`/`mirai::daemons()` not covered (same fresh-session rules expected, not verified).
- The crew "no `box.path` works" result relies on worker cwd; I did not trace box internals to confirm the exact mechanism.

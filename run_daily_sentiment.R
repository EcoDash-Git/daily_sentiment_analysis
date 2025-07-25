#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# run_daily_sentiment.R
# ---------------------------------------------------------------------------
# * Renders tweet_report_daily.Rmd → HTML
# * Prints the HTML to PDF (pagedown + headless Chrome)
# * Uploads the PDF to Supabase (bucket: daily‑sentiment/YYYYwWW/…)
# * Emails the PDF via Mailjet
# ---------------------------------------------------------------------------

## ── 0. Packages ────────────────────────────────────────────────────────────
required <- c(
  "tidyverse", "lubridate", "jsonlite", "httr2", "httr", "glue",
  "rmarkdown", "pagedown", "RPostgres", "DBI", "base64enc"
)
invisible(lapply(required, \(p) {
  if (!requireNamespace(p, quietly = TRUE))
    install.packages(p, quiet = TRUE)
  library(p, character.only = TRUE)
}))

# infix “or‑else” helper
"%||%" <- function(a, b) if (nzchar(a)) a else b

## ── 1. Configuration & env vars ────────────────────────────────────────────
REPORT_DATE <- (Sys.getenv("REPORT_DATE") %>% as.Date()) %||% Sys.Date()

RMD_FILE  <- "tweet_report_daily.Rmd"      # <- your RMarkdown filename
HTML_OUT  <- "daily_sentiment_report.html"
PDF_OUT   <- "daily_sentiment_report.pdf"

SB_URL         <- Sys.getenv("SUPABASE_URL")
SB_STORAGE_KEY <- Sys.getenv("SUPABASE_SERVICE_ROLE")
SB_BUCKET      <- "daily-sentiment"        # bucket name

MJ_API_KEY  <- Sys.getenv("MJ_API_KEY")
MJ_API_SECRET <- Sys.getenv("MJ_API_SECRET")
MAIL_FROM   <- Sys.getenv("MAIL_FROM")
MAIL_TO     <- Sys.getenv("MAIL_TO")

stopifnot(
  SB_URL != "", SB_STORAGE_KEY != "",
  MJ_API_KEY != "", MJ_API_SECRET != "",
  MAIL_FROM != "", MAIL_TO != ""
)

## ── 2. Knit RMarkdown → HTML ───────────────────────────────────────────────
rmarkdown::render(
  input        = RMD_FILE,
  output_file  = HTML_OUT,
  params       = list(report_date = REPORT_DATE),
  quiet        = TRUE
)

## ── 3. HTML → PDF (pagedown) ───────────────────────────────────────────────
chrome_path <- Sys.getenv("CHROME_BIN")
if (!nzchar(chrome_path)) chrome_path <- pagedown::find_chrome()
cat("Using Chrome at:", chrome_path, "\n")

pagedown::chrome_print(
  input      = HTML_OUT,
  output     = PDF_OUT,
  browser    = chrome_path,
  extra_args = c("--no-sandbox")
)

if (!file.exists(PDF_OUT))
  stop("❌ PDF not generated – ", PDF_OUT, " missing")

## ── 4. Upload PDF to Supabase storage ──────────────────────────────────────
object_path <- sprintf(
  "%s/%s_%s.pdf",
  format(Sys.Date(), "%Yw%V"),            # folder: YYYYwWW
  REPORT_DATE, format(Sys.time(), "%H-%M-%S")
)

upload_url <- sprintf(
  "%s/storage/v1/object/%s/%s?upload=1",
  SB_URL, SB_BUCKET, object_path
)

resp <- request(upload_url) |>
  req_method("POST") |>
  req_headers(
    Authorization  = sprintf("Bearer %s", SB_STORAGE_KEY),
    "x-upsert"     = "true",
    "Content-Type" = "application/pdf"
  ) |>
  req_body_file(PDF_OUT) |>
  req_error(is_error = \(x) FALSE) |>
  req_perform()

stopifnot(resp_status(resp) < 300)
cat("✔ Uploaded to Supabase:", object_path, "\n")

## ── 5. Email the PDF via Mailjet ───────────────────────────────────────────
from_email <- if (str_detect(MAIL_FROM, "<.+@.+>"))
  str_remove_all(str_extract(MAIL_FROM, "<.+@.+>"), "[<>]") else MAIL_FROM
from_name  <- if (str_detect(MAIL_FROM, "<.+@.+>"))
  str_trim(str_remove(MAIL_FROM, "<.+@.+>$")) else "Sentiment Bot"

mj_resp <- request("https://api.mailjet.com/v3.1/send") |>
  req_auth_basic(MJ_API_KEY, MJ_API_SECRET) |>
  req_body_json(list(
    Messages = list(list(
      From        = list(Email = from_email, Name = from_name),
      To          = list(list(Email = MAIL_TO)),
      Subject     = sprintf("Daily Sentiment Report – %s", REPORT_DATE),
      TextPart    = "Attached you'll find the daily sentiment report in PDF.",
      Attachments = list(list(
        ContentType   = "application/pdf",
        Filename      = sprintf("sentiment_%s.pdf", REPORT_DATE),
        Base64Content = base64enc::base64encode(PDF_OUT)
      ))
    ))
  )) |>
  req_error(is_error = \(x) FALSE) |>
  req_perform()

stopifnot(resp_status(mj_resp) < 300)
cat("📧  Mailjet response OK — report emailed\n")


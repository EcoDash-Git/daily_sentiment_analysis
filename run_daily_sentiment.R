#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# run_daily_sentiment.R
# ---------------------------------------------------------------------------
# Knit tweet_report_daily.Rmd  -> HTML -> PDF
# Upload PDF to Supabase (bucket daily‑sentiment/yyyywWW/…)
# Mail PDF via Mailjet
# ---------------------------------------------------------------------------

## 0 ── packages --------------------------------------------------------------
pkgs <- c("tidyverse","jsonlite","httr2","rmarkdown","pagedown",
          "DBI","RPostgres","base64enc")
invisible(lapply(pkgs, \(p){
  if (!requireNamespace(p, quietly = TRUE))
    install.packages(p, quiet = TRUE)
  library(p, character.only = TRUE)
}))

`%||%` <- function(a,b){
  if (isTRUE(is.na(a)) || (is.character(a) && !nzchar(a))) b else a
}

## 1 ── config / env ----------------------------------------------------------
# try to parse env var; fall back to today if empty **or** unparsable
date_env   <- Sys.getenv("REPORT_DATE")
REPORT_DATE<- suppressWarnings(as.Date(date_env)) %||% Sys.Date()

RMD_FILE   <- "tweet_report_daily.Rmd"
HTML_OUT   <- "daily_sentiment_report.html"
PDF_OUT    <- "daily_sentiment_report.pdf"

SB_URL         <- Sys.getenv("SUPABASE_URL")
SB_STORAGE_KEY <- Sys.getenv("SUPABASE_SERVICE_ROLE")
SB_BUCKET      <- "daily-sentiment"

MJ_API_KEY     <- Sys.getenv("MJ_API_KEY")
MJ_API_SECRET  <- Sys.getenv("MJ_API_SECRET")
MAIL_FROM      <- Sys.getenv("MAIL_FROM")
MAIL_TO        <- Sys.getenv("MAIL_TO")

stopifnot(
  SB_URL      != "", SB_STORAGE_KEY != "",
  MJ_API_KEY  != "", MJ_API_SECRET  != "",
  MAIL_FROM   != "", MAIL_TO        != ""
)

## 2 ── knit Rmd --------------------------------------------------------------
rmarkdown::render(
  input       = RMD_FILE,
  output_file = HTML_OUT,
  params      = list(report_date = REPORT_DATE),
  quiet       = TRUE
)

## 3 ── HTML -> PDF -----------------------------------------------------------
chrome_path <- Sys.getenv("CHROME_BIN", pagedown::find_chrome())
cat("Using Chrome at:", chrome_path, "\n")

pagedown::chrome_print(
  input   = HTML_OUT,
  output  = PDF_OUT,
  browser = chrome_path,
  extra_args = "--no-sandbox"
)

if (!file.exists(PDF_OUT))
  stop("❌ PDF not generated – ", PDF_OUT, " missing")

## 4 ── upload to Supabase ----------------------------------------------------
object_path <- sprintf(
  "%s/%s_%s.pdf",
  format(Sys.Date(), "%Yw%V"),       # yyyywWW
  format(REPORT_DATE, "%Y-%m-%d"),   # always defined now
  format(Sys.time(), "%H-%M-%S")
)

upload_url <- sprintf("%s/storage/v1/object/%s/%s?upload=1",
                      SB_URL, SB_BUCKET, object_path)

resp <- request(upload_url) |>
  req_method("POST") |>
  req_headers(
    Authorization  = sprintf("Bearer %s", SB_STORAGE_KEY),
    `x-upsert`     = "true",
    `Content-Type` = "application/pdf"
  ) |>
  req_body_file(PDF_OUT) |>
  req_perform()

stopifnot(resp_status(resp) < 300)
cat("✔ Uploaded to Supabase:", object_path, "\n")

## 5 ── email via Mailjet -----------------------------------------------------
## 5 ── email via Mailjet -----------------------------------------------------
from_email <- if (str_detect(MAIL_FROM, "<.+@.+>")) {
  str_remove_all(str_extract(MAIL_FROM, "<.+@.+>"), "[<>]")
} else {
  MAIL_FROM
}

from_name  <- if (str_detect(MAIL_FROM, "<.+@.+>")) {
  str_trim(str_remove(MAIL_FROM, "<.+@.+>$"))
} else {
  "Sentiment Bot"
}

mj_resp <- request("https://api.mailjet.com/v3.1/send") |>
  req_auth_basic(MJ_API_KEY, MJ_API_SECRET) |>
  req_body_json(list(
    Messages = list(list(
      From        = list(Email = from_email, Name = from_name),
      To          = list(list(Email = MAIL_TO)),
      Subject     = sprintf("Daily Sentiment Report – %s", REPORT_DATE),
      TextPart    = "Attached you'll find the daily sentiment report.",
      Attachments = list(list(
        ContentType   = "application/pdf",
        Filename      = sprintf("sentiment_%s.pdf", REPORT_DATE),
        Base64Content = base64enc::base64encode(PDF_OUT)
      ))
    ))
  )) |>
  req_error(is_error = \(x) FALSE) |>   # ← NEW: never stop on HTTP ≥400
  req_perform()

if (resp_status(mj_resp) >= 300) {
  cat("Mailjet response (status", resp_status(mj_resp), "):\n",
      resp_body_string(mj_resp, encoding = "UTF-8"), "\n")
  stop("❌ Mailjet returned HTTP ", resp_status(mj_resp))
}

cat("📧  Mailjet response OK — report emailed\n")

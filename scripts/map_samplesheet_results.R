#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)

usage <- function() {
  cat(
    "Usage:\n",
    "  Rscript scripts/map_samplesheet_results.R",
    " --agrf-sheet <metadata_samplesheet.txt>",
    " --consolidated-dir <dir>",
    " --output <file.tsv>\n",
    "\n",
    "Optional overrides:\n",
    "  --mlst <file>\n",
    "  --kleborate <file>\n",
    "  --fimtyper <file>\n",
    "  --abritamr <file>\n",
    "  --plasmidfinder <file>\n",
    "  --bracken <file>\n",
    "\n",
    "Notes:\n",
    "  - Metadata headers 'Sample name' and 'Comments' are preferred.\n",
    "  - If those headers are missing, the first metadata column is treated as\n",
    "    'Sample name' and the second as 'Comments'.\n",
    "  - All other metadata columns are ignored by this script.\n",
    "  - If explicit result files are not provided, the script tries to locate\n",
    "    consolidated tool tables under --consolidated-dir.\n",
    sep = ""
  )
}

parse_args <- function(x) {
  if (!length(x) || length(x) %% 2L != 0L) {
    usage()
    stop("Arguments must be supplied as --key value pairs.", call. = FALSE)
  }

  out <- list()
  i <- 1L
  while (i <= length(x)) {
    key <- x[[i]]
    value <- x[[i + 1L]]
    if (!startsWith(key, "--")) {
      usage()
      stop("Invalid argument: ", key, call. = FALSE)
    }
    out[[substring(key, 3L)]] <- value
    i <- i + 2L
  }
  out
}

opts <- parse_args(args)

agrf_sheet <- opts[["agrf-sheet"]]
consolidated_dir <- opts[["consolidated-dir"]]
output_file <- opts[["output"]]
mlst_file <- opts[["mlst"]]
kleborate_file <- opts[["kleborate"]]
fimtyper_file <- opts[["fimtyper"]]
abritamr_file <- opts[["abritamr"]]
plasmidfinder_file <- opts[["plasmidfinder"]]
bracken_file <- opts[["bracken"]]

if (is.null(agrf_sheet) || !file.exists(agrf_sheet)) {
  stop("`--agrf-sheet` must point to an existing metadata samplesheet.", call. = FALSE)
}

if (is.null(consolidated_dir) || !dir.exists(consolidated_dir)) {
  stop("`--consolidated-dir` must point to an existing directory.", call. = FALSE)
}

if (is.null(output_file) || !nzchar(output_file)) {
  stop("`--output` is required.", call. = FALSE)
}

read_table_flex <- function(path) {
  ext <- tolower(tools::file_ext(path))

  if (requireNamespace("readr", quietly = TRUE)) {
    if (ext == "csv") {
      return(as.data.frame(readr::read_csv(path, show_col_types = FALSE, progress = FALSE, guess_max = 100000)))
    }
    return(as.data.frame(readr::read_tsv(path, show_col_types = FALSE, progress = FALSE, guess_max = 100000)))
  }

  if (ext == "csv") {
    return(utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE))
  }

  utils::read.delim(path, check.names = FALSE, stringsAsFactors = FALSE)
}

write_tsv_flex <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)

  if (requireNamespace("readr", quietly = TRUE)) {
    readr::write_tsv(x, path, na = "")
  } else {
    utils::write.table(x, file = path, sep = "\t", row.names = FALSE, quote = FALSE, na = "")
  }
  invisible(path)
}

to_snake_case <- function(x) {
  x <- gsub("([a-z0-9])([A-Z])", "\\1_\\2", x)
  x <- gsub("[^A-Za-z0-9]+", "_", x)
  x <- gsub("_+", "_", x)
  x <- gsub("^_|_$", "", x)
  tolower(x)
}

normalize_sample <- function(x) {
  x <- trimws(as.character(x))
  x[nchar(x) == 0L] <- NA_character_
  x <- sub("\\.(fna|fa|fasta)(\\.gz)?$", "", x, ignore.case = TRUE)
  x
}

normalize_header <- function(x) {
  x <- trimws(as.character(x))
  x <- gsub("\\s+", " ", x)
  tolower(x)
}

find_first_existing <- function(paths) {
  matches <- paths[file.exists(paths)]
  if (length(matches)) {
    return(matches[[1L]])
  }
  NULL
}

find_tool_merged_file <- function(root, tool_name) {
  candidates <- c(
    file.path(root, "tools", paste0("results_", tool_name), "merged-results", paste0(tool_name, "_merged.tsv")),
    file.path(root, "tools", paste0("results_", tool_name), "merged-results", paste0(tool_name, ".tsv")),
    file.path(root, "tools", paste0("results_", tool_name), "merged-results", paste0(tool_name, ".txt")),
    file.path(root, paste0("results_", tool_name), "merged-results", paste0(tool_name, "_merged.tsv")),
    file.path(root, paste0("results_", tool_name), "merged-results", paste0(tool_name, ".tsv")),
    file.path(root, paste0("results_", tool_name), "merged-results", paste0(tool_name, ".txt"))
  )
  find_first_existing(candidates)
}

find_mlst_file <- function(root) {
  candidates <- c(
    file.path(root, "tools", "results_mlst", "merged-results", "mlst_merged.tsv"),
    file.path(root, "tools", "results_mlst", "merged-results", "mlst.tsv"),
    file.path(root, "tools", "results_mlst", "merged-results", "mlst_summary.tsv"),
    file.path(root, "tools", "results_mlst", "merged-results", "mlst.csv"),
    file.path(root, "results_main", "merged-results", "mlst_merged.tsv"),
    file.path(root, "results_main", "merged-results", "mlst.tsv"),
    file.path(root, "results_main", "merged-results", "mlst_summary.tsv"),
    file.path(root, "results_main", "merged-results", "mlst.csv")
  )
  find_first_existing(candidates)
}

looks_like_sample_value <- function(x) {
  if (!length(x) || is.na(x)) {
    return(FALSE)
  }
  grepl("^[0-9]{2}GNB-", x) || grepl("\\.(fna|fa|fasta)(\\.gz)?$", x, ignore.case = TRUE)
}

find_kleborate_file <- function(root) {
  preferred <- c(
    file.path(root, "tools", "results_kleborate", "merged-results", "kleborate_merged.tsv"),
    file.path(root, "tools", "results_kleborate", "merged-results", "kleborate.tsv"),
    file.path(root, "tools", "results_kleborate", "merged-results", "kleborate.txt"),
    file.path(root, "results_kleborate", "merged-results", "kleborate_merged.tsv"),
    file.path(root, "results_kleborate", "merged-results", "kleborate.tsv"),
    file.path(root, "results_kleborate", "merged-results", "kleborate.txt")
  )
  hit <- find_first_existing(preferred)
  if (!is.null(hit)) {
    return(hit)
  }

  search_root <- file.path(root, "tools")
  if (!dir.exists(search_root)) {
    return(NULL)
  }

  candidates <- list.files(
    search_root,
    pattern = "\\.(tsv|csv|txt)$",
    recursive = TRUE,
    full.names = TRUE
  )

  for (candidate in candidates) {
    if (!grepl("kleborate", candidate, ignore.case = TRUE)) {
      next
    }
    header <- tryCatch(readLines(candidate, n = 1L, warn = FALSE), error = function(e) "")
    if (length(header) && grepl("enterobacterales__species__species|strain", header, ignore.case = TRUE)) {
      return(candidate)
    }
  }

  NULL
}

find_fimtyper_file <- function(root) {
  preferred <- c(
    file.path(root, "tools", "results_fimtyper", "merged-results", "fimtyper_merged.tsv"),
    file.path(root, "tools", "results_fimtyper", "merged-results", "fimtyper.tsv"),
    file.path(root, "results_fimtyper", "merged-results", "fimtyper_merged.tsv"),
    file.path(root, "results_fimtyper", "merged-results", "fimtyper.tsv")
  )
  hit <- find_first_existing(preferred)
  if (!is.null(hit)) {
    return(hit)
  }

  search_root <- file.path(root, "tools")
  if (!dir.exists(search_root)) {
    return(NULL)
  }

  candidates <- list.files(
    search_root,
    pattern = "\\.(tsv|csv|txt)$",
    recursive = TRUE,
    full.names = TRUE
  )

  score_candidate <- function(path) {
    name_score <- as.integer(grepl("fim", basename(path), ignore.case = TRUE))
    header <- tryCatch(readLines(path, n = 1L, warn = FALSE), error = function(e) "")
    if (!length(header)) {
      return(-Inf)
    }
    header_score <- as.integer(grepl("sample|strain|isolate|fim", header, ignore.case = TRUE))
    name_score + header_score
  }

  scores <- vapply(candidates, score_candidate, numeric(1))
  if (!length(scores) || all(!is.finite(scores)) || max(scores) <= 0) {
    return(NULL)
  }

  candidates[[which.max(scores)]]
}

detect_sample_col <- function(dat) {
  name_map <- to_snake_case(names(dat))
  preferred <- c("sample", "sample_name", "strain", "isolate", "id", "name")
  for (candidate in preferred) {
    hit <- which(name_map == candidate)
    if (length(hit)) {
      return(names(dat)[hit[[1L]]])
    }
  }
  NULL
}

prefix_non_key_cols <- function(dat, prefix) {
  key_cols <- c("sample")
  for (nm in names(dat)) {
    if (nm %in% key_cols) {
      next
    }
    names(dat)[names(dat) == nm] <- paste0(prefix, nm)
  }
  dat
}

read_agrf_sheet <- function(path) {
  required_cols <- c(
    "Sample name",
    "Comments"
  )
  dat <- read_table_flex(path)

  if (ncol(dat) < 2L) {
    stop(
      "Metadata sheet must contain at least two columns so the first can be used as 'Sample name' and the second as 'Comments'.",
      call. = FALSE
    )
  }

  if (anyDuplicated(names(dat))) {
    dupes <- unique(names(dat)[duplicated(names(dat))])
    stop(
      "Metadata sheet contains duplicated column names: ",
      paste(dupes, collapse = ", "),
      call. = FALSE
    )
  }

  header_keys <- normalize_header(names(dat))
  required_keys <- normalize_header(required_cols)
  required_idx <- match(required_keys, header_keys)

  if (all(!is.na(required_idx))) {
    dat <- dat[required_idx]
    names(dat) <- required_cols
  } else {
    fallback_names <- names(dat)[seq_len(2L)]
    message(
      "Metadata sheet is missing the preferred 'Sample name' and/or 'Comments' headers. ",
      "Using first column '", fallback_names[[1]], "' as 'Sample name' and second column '",
      fallback_names[[2]], "' as 'Comments'."
    )
    dat <- dat[seq_len(2L)]
    names(dat) <- required_cols
  }

  dat[["Comments"]] <- as.character(dat[["Comments"]])
  dat$sample <- normalize_sample(dat[["Sample name"]])
  dat
}

read_mlst_table <- function(path) {
  if (is.null(path)) {
    return(NULL)
  }

  parse_structured_mlst <- function(dat) {
    if (is.null(dat) || !nrow(dat)) {
      return(NULL)
    }

    if ("resolved_scheme" %in% names(dat) && !"scheme" %in% names(dat)) {
      names(dat)[names(dat) == "resolved_scheme"] <- "scheme"
    } else if ("auto_scheme" %in% names(dat) && !"scheme" %in% names(dat)) {
      names(dat)[names(dat) == "auto_scheme"] <- "scheme"
    }
    if ("resolved_st" %in% names(dat) && !"st" %in% names(dat)) {
      names(dat)[names(dat) == "resolved_st"] <- "st"
    } else if ("auto_st" %in% names(dat) && !"st" %in% names(dat)) {
      names(dat)[names(dat) == "auto_st"] <- "st"
    }
    if ("resolved_profile" %in% names(dat) && !"profile" %in% names(dat)) {
      names(dat)[names(dat) == "resolved_profile"] <- "profile"
    } else if ("auto_profile" %in% names(dat) && !"profile" %in% names(dat)) {
      names(dat)[names(dat) == "auto_profile"] <- "profile"
    }

    if ("sample_name" %in% names(dat) && !"sample" %in% names(dat)) {
      names(dat)[names(dat) == "sample_name"] <- "sample"
    }
    if (!"sample" %in% names(dat)) {
      sample_col <- detect_sample_col(dat)
      if (is.null(sample_col)) {
        return(NULL)
      }
      names(dat)[names(dat) == sample_col] <- "sample"
    }
    dat$sample <- normalize_sample(dat$sample)
    if ("sequence_type" %in% names(dat) && !"st" %in% names(dat)) {
      names(dat)[names(dat) == "sequence_type"] <- "st"
    }
    review_meta_cols <- c("warning", "warnings", "note", "notes", "comment", "comments")
    locus_cols <- setdiff(
      names(dat),
      c(
        "sample", "scheme", "st", "profile", "batch_name", "source_file",
        "auto_scheme", "auto_st", "auto_profile",
        "resolved_scheme", "resolved_st", "resolved_profile",
        "resolution_note", "warning_score", "agrf_comments", "source_assembly",
        review_meta_cols
      )
    )
    if (!"profile" %in% names(dat)) {
      if (length(locus_cols)) {
        dat$profile <- apply(dat[locus_cols], 1L, function(row) {
          vals <- trimws(as.character(row))
          vals <- vals[nzchar(vals) & !is.na(vals)]
          paste(vals, collapse = " ")
        })
      } else {
        dat$profile <- NA_character_
      }
    } else {
      dat$profile <- trimws(as.character(dat$profile))
      dat$profile[!nzchar(dat$profile)] <- NA_character_
    }
    extra_review_cols <- intersect(review_meta_cols, names(dat))
    keep <- unique(c("sample", intersect(c("scheme", "st", "profile"), names(dat)), extra_review_cols))
    dat <- dat[keep]
    if (!nrow(dat)) {
      return(NULL)
    }
    prefix_non_key_cols(dat, "mlst_")
  }

  structured <- tryCatch(read_table_flex(path), error = function(e) NULL)
  structured <- parse_structured_mlst(structured)
  if (!is.null(structured)) {
    return(structured)
  }

  lines <- readLines(path, warn = FALSE)
  if (!length(lines)) {
    return(NULL)
  }

  tokens <- unlist(strsplit(paste(lines, collapse = " "), "[[:space:]]+"))
  tokens <- tokens[nzchar(tokens)]
  if (!length(tokens)) {
    return(NULL)
  }

  # Any assembly filename token starts a sample record -- not just AGAR (NNGNB-NNN)
  # names. The old AGAR-only pattern made this headerless-MLST fallback yield nothing
  # for non-AGAR projects. Match any non-path token ending in .fna/.fa/.fasta(.gz).
  is_sample_token <- function(x) {
    grepl("^[^/[:space:]]+\\.(fna|fa|fasta)(\\.gz)?$", x, ignore.case = TRUE)
  }

  is_batch_token <- function(x) {
    grepl("^[[:alnum:]_]+_[0-9]{3}$", x)
  }

  is_path_token <- function(x) {
    grepl("^/", x)
  }

  is_st_token <- function(x) {
    grepl("^[0-9]+$", x) || identical(x, "-")
  }

  sample_idx <- which(vapply(tokens, is_sample_token, logical(1)))
  if (!length(sample_idx)) {
    return(NULL)
  }

  rows <- vector("list", length(sample_idx))

  for (i in seq_along(sample_idx)) {
    start <- sample_idx[[i]]
    end <- if (i < length(sample_idx)) sample_idx[[i + 1L]] - 1L else length(tokens)
    rec <- tokens[start:end]
    rec <- rec[!vapply(rec, is_batch_token, logical(1))]
    rec <- rec[!vapply(rec, is_path_token, logical(1))]
    rec <- rec[!rec %in% c("batch_name", "source_file")]

    if (length(rec) < 2L) {
      next
    }

    sample <- normalize_sample(rec[[1L]])
    second <- if (length(rec) >= 2L) rec[[2L]] else NA_character_
    third <- if (length(rec) >= 3L) rec[[3L]] else NA_character_

    if (!is.na(second) && is_st_token(second)) {
      scheme <- NA_character_
      st <- second
      profile_tokens <- if (length(rec) >= 3L) rec[3:length(rec)] else character()
    } else {
      scheme <- second
      st <- if (!is.na(third) && is_st_token(third)) third else NA_character_
      profile_tokens <- if (length(rec) >= 4L) rec[4:length(rec)] else character()
    }

    profile_tokens <- profile_tokens[
      nzchar(profile_tokens) &
        !is_batch_token(profile_tokens) &
        !is_path_token(profile_tokens)
    ]

    rows[[i]] <- data.frame(
      sample = sample,
      scheme = scheme,
      st = st,
      profile = if (length(profile_tokens)) paste(profile_tokens, collapse = " ") else NA_character_,
      stringsAsFactors = FALSE
    )
  }

  rows <- Filter(Negate(is.null), rows)
  if (!length(rows)) {
    return(NULL)
  }

  dat <- do.call(rbind, rows)
  dat <- dat[!is.na(dat$sample) & !duplicated(dat$sample), , drop = FALSE]
  rownames(dat) <- NULL
  prefix_non_key_cols(dat, "mlst_")
}

read_kleborate_table <- function(path) {
  if (is.null(path)) {
    return(NULL)
  }

  dat <- read_table_flex(path)
  names(dat) <- to_snake_case(names(dat))

  if ("strain" %in% names(dat) && !"sample" %in% names(dat)) {
    names(dat)[names(dat) == "strain"] <- "sample"
  } else if (!"sample" %in% names(dat)) {
    sample_col <- detect_sample_col(dat)
    if (is.null(sample_col)) {
      return(NULL)
    }
    names(dat)[names(dat) == sample_col] <- "sample"
  }

  dat$sample <- normalize_sample(dat$sample)
  keep <- unique(c(
    "sample",
    intersect(
      c("species", "species_match", "st", "virulence_score", "resistance_score", "k_locus", "k_type", "o_locus", "o_type"),
      names(dat)
    )
  ))
  dat <- dat[keep]
  prefix_non_key_cols(dat, "kleborate_")
}

read_fimtyper_table <- function(path) {
  if (is.null(path)) {
    return(NULL)
  }

  dat <- read_table_flex(path)
  names(dat) <- to_snake_case(names(dat))

  sample_col <- detect_sample_col(dat)
  if (is.null(sample_col)) {
    return(NULL)
  }
  names(dat)[names(dat) == sample_col] <- "sample"
  dat$sample <- normalize_sample(dat$sample)
  keep <- unique(c("sample", intersect(c("fimtype", "identity"), names(dat))))
  dat <- dat[keep]
  prefix_non_key_cols(dat, "fimtyper_")
}

read_generic_tool_table <- function(path, prefix, keep_cols = NULL) {
  if (is.null(path)) {
    return(NULL)
  }

  dat <- read_table_flex(path)
  if (is.null(dat) || !nrow(dat)) {
    return(NULL)
  }

  names(dat) <- to_snake_case(names(dat))
  sample_col <- detect_sample_col(dat)
  if (is.null(sample_col)) {
    return(NULL)
  }

  names(dat)[names(dat) == sample_col] <- "sample"
  dat$sample <- normalize_sample(dat$sample)

  if (is.null(keep_cols)) {
    keep_cols <- setdiff(names(dat), c("batch_name", "source_file"))
  } else {
    keep_cols <- unique(c("sample", intersect(keep_cols, names(dat))))
  }

  dat <- dat[keep_cols]
  prefix_non_key_cols(dat, prefix)
}

read_bracken_table <- function(path) {
  if (is.null(path)) {
    return(NULL)
  }

  dat <- read_table_flex(path)
  if (is.null(dat) || !nrow(dat)) {
    return(NULL)
  }

  names(dat) <- to_snake_case(names(dat))
  sample_col <- detect_sample_col(dat)
  if (is.null(sample_col)) {
    return(NULL)
  }

  names(dat)[names(dat) == sample_col] <- "sample"
  dat$sample <- normalize_sample(dat$sample)

  summary_cols <- c(
    "sample",
    "bracken_primary_species",
    "bracken_primary_species_abundance",
    "bracken_secondary_species",
    "bracken_secondary_species_abundance",
    "bracken_unclassified_abundance"
  )

  if (all(summary_cols[-1L] %in% names(dat))) {
    dat <- dat[intersect(summary_cols, names(dat))]
    return(dat)
  }

  prefix_non_key_cols(dat, "bracken_")
}

dedupe_by_sample <- function(dat) {
  if (is.null(dat) || !"sample" %in% names(dat) || !nrow(dat)) {
    return(dat)
  }
  dat <- dat[!is.na(dat$sample) & !duplicated(dat$sample), , drop = FALSE]
  rownames(dat) <- NULL
  dat
}

collect_result_samples <- function(...) {
  tables <- list(...)
  samples <- character()

  for (dat in tables) {
    if (is.null(dat) || !"sample" %in% names(dat) || !nrow(dat)) {
      next
    }
    current <- dat$sample
    current <- current[!is.na(current) & nzchar(current)]
    current <- current[!current %in% samples]
    if (length(current)) {
      samples <- c(samples, current)
    }
  }

  if (!length(samples)) {
    return(NULL)
  }

  data.frame(sample = samples, stringsAsFactors = FALSE)
}

coalesce_nonempty_scalar <- function(...) {
  values <- list(...)
  for (value in values) {
    if (length(value) == 0L || is.null(value) || is.na(value)) {
      next
    }
    value <- trimws(as.character(value[[1L]]))
    if (nzchar(value)) {
      return(value)
    }
  }
  NA_character_
}

extract_genus_token <- function(x) {
  if (length(x) == 0L || is.null(x) || is.na(x)) {
    return(NA_character_)
  }

  x <- tolower(trimws(as.character(x[[1L]])))
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  if (!nzchar(x)) {
    return(NA_character_)
  }

  parts <- strsplit(x, "_", fixed = TRUE)[[1L]]
  parts <- parts[nzchar(parts)]
  if (!length(parts)) {
    return(NA_character_)
  }

  parts[[1L]]
}

normalize_taxon_token <- function(x) {
  if (length(x) == 0L || is.null(x) || is.na(x)) {
    return(NA_character_)
  }

  x <- trimws(tolower(as.character(x[[1L]])))
  if (!nzchar(x)) {
    return(NA_character_)
  }

  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  x <- gsub("_+", "_", x)
  if (!nzchar(x)) {
    return(NA_character_)
  }

  x
}

canonical_genus_map <- c(
  escheria = "escherichia",
  escherichia = "escherichia",
  kleb = "klebsiella",
  klebsiella = "klebsiella",
  salmonella = "salmonella",
  serratia = "serratia",
  proteus = "proteus",
  cronobacter = "cronobacter",
  enterobacter = "enterobacter",
  citrobacter = "citrobacter",
  morganella = "morganella",
  providencia = "providencia",
  pseudomonas = "pseudomonas",
  raoultella = "raoultella",
  unknown = "unknown"
)

mlst_scheme_token_map <- c(
  ecoli = "escherichia",
  e_coli = "escherichia",
  senterica = "salmonella",
  salmonella = "salmonella",
  serratia = "serratia",
  proteus = "proteus",
  cronobacter = "cronobacter",
  cloacae = "enterobacter",
  enterobacter = "enterobacter",
  cfreundii = "citrobacter",
  citrobacter = "citrobacter",
  morganella = "morganella",
  providencia = "providencia",
  paeruginosa = "pseudomonas",
  pseudomonas = "pseudomonas",
  unknown = "unknown"
)

species_epithet_genus_map <- c(
  coli = "escherichia",
  enterica = "salmonella",
  pneumoniae = "klebsiella",
  quasipneumoniae = "klebsiella",
  variicola = "klebsiella",
  oxytoca = "klebsiella",
  aerogenes = "klebsiella",
  cloacae = "enterobacter",
  freundii = "citrobacter",
  braakii = "citrobacter",
  koseri = "citrobacter",
  marcescens = "serratia",
  mirabilis = "proteus",
  vulgaris = "proteus",
  terrae = "proteus",
  morganii = "morganella",
  rettgeri = "providencia",
  stuartii = "providencia",
  aeruginosa = "pseudomonas"
)

canonicalize_scheme_genus <- function(x) {
  token <- normalize_taxon_token(extract_genus_token(x))
  if (is.na(token)) {
    return(NA_character_)
  }

  if (token %in% names(mlst_scheme_token_map)) {
    return(unname(mlst_scheme_token_map[[token]]))
  }

  if (token %in% names(canonical_genus_map)) {
    return(unname(canonical_genus_map[[token]]))
  }

  if (grepl("^[a-z][a-z]+$", token)) {
    epithet <- substring(token, 2L)
    if (epithet %in% names(species_epithet_genus_map)) {
      return(unname(species_epithet_genus_map[[epithet]]))
    }
  }

  token
}

canonicalize_species_genus <- function(x) {
  text <- normalize_taxon_token(x)
  if (is.na(text)) {
    return(NA_character_)
  }

  parts <- strsplit(text, "_", fixed = TRUE)[[1L]]
  parts <- parts[nzchar(parts)]
  if (!length(parts)) {
    return(NA_character_)
  }

  genus <- parts[[1L]]
  species <- if (length(parts) >= 2L) parts[[2L]] else NA_character_

  if (!is.na(species) && genus == "enterobacter" && species == "aerogenes") {
    return("klebsiella")
  }

  if (genus %in% names(canonical_genus_map)) {
    return(unname(canonical_genus_map[[genus]]))
  }

  if (genus %in% names(mlst_scheme_token_map)) {
    return(unname(mlst_scheme_token_map[[genus]]))
  }

  if (!is.na(species) && species %in% names(species_epithet_genus_map)) {
    return(unname(species_epithet_genus_map[[species]]))
  }

  genus
}

is_informative_genus <- function(x) {
  !is.na(x) && nzchar(x) && !identical(x, "unknown")
}

flag_review_columns <- function(dat) {
  n <- nrow(dat)
  dat$review_required <- rep("no", n)
  dat$review_reason <- rep(NA_character_, n)
  dat$mlst_canonical_genus <- rep(NA_character_, n)
  dat$phenotype_canonical_genus <- rep(NA_character_, n)

  if (!n) {
    return(dat)
  }

  for (i in seq_len(n)) {
    reasons <- character()
    mlst_scheme <- coalesce_nonempty_scalar(dat$mlst_scheme[[i]])
    phenotype_label <- coalesce_nonempty_scalar(
      if ("Comments" %in% names(dat)) dat[["Comments"]][[i]] else NA_character_
    )
    mlst_profile <- coalesce_nonempty_scalar(dat$mlst_profile[[i]])
    mlst_review_text <- coalesce_nonempty_scalar(
      if ("mlst_warning" %in% names(dat)) dat$mlst_warning[[i]] else NA_character_,
      if ("mlst_warnings" %in% names(dat)) dat$mlst_warnings[[i]] else NA_character_,
      if ("mlst_note" %in% names(dat)) dat$mlst_note[[i]] else NA_character_,
      if ("mlst_notes" %in% names(dat)) dat$mlst_notes[[i]] else NA_character_,
      if ("mlst_comment" %in% names(dat)) dat$mlst_comment[[i]] else NA_character_,
      if ("mlst_comments" %in% names(dat)) dat$mlst_comments[[i]] else NA_character_
    )

    mlst_genus <- canonicalize_scheme_genus(mlst_scheme)
    phenotype_genus <- canonicalize_species_genus(phenotype_label)
    dat$mlst_canonical_genus[[i]] <- mlst_genus
    dat$phenotype_canonical_genus[[i]] <- phenotype_genus

    if (is_informative_genus(mlst_genus) && is_informative_genus(phenotype_genus) && mlst_genus != phenotype_genus) {
      reasons <- c(reasons, "Phenotype and MLST discordance")
    }

    if (!is.na(mlst_profile) && grepl("\\?", mlst_profile)) {
      reasons <- c(reasons, "MLST needs review")
    }

    if (!is.na(mlst_review_text) && (
      grepl("==", mlst_review_text, fixed = TRUE) ||
      grepl("score\\s*=", mlst_review_text, ignore.case = TRUE) ||
      grepl("warning", mlst_review_text, ignore.case = TRUE) ||
      grepl("ambig", mlst_review_text, ignore.case = TRUE)
    )) {
      reasons <- c(reasons, "MLST ambiguous")
    }

    reasons <- unique(reasons)
    if (length(reasons)) {
      dat$review_required[[i]] <- "yes"
      dat$review_reason[[i]] <- paste(reasons, collapse = "; ")
    }
  }

  dat
}

review_output_path <- function(path) {
  dir_name <- dirname(path)
  ext <- tools::file_ext(path)
  stub <- basename(path)
  if (nzchar(ext)) {
    stub <- substr(stub, 1L, nchar(stub) - nchar(ext) - 1L)
  }
  file.path(dir_name, paste0(stub, "_review_required.tsv"))
}

message_path <- function(label, path) {
  if (is.null(path)) {
    message(label, ": not found")
  } else {
    message(label, ": ", normalizePath(path, winslash = "/", mustWork = FALSE))
  }
}

script_path <- tryCatch(normalizePath(sys.frames()[[1]]$ofile, winslash = "/", mustWork = TRUE), error = function(e) NA_character_)
if (is.na(script_path) || !nzchar(script_path)) {
  script_path <- "unknown"
}
message("Using mapper script: ", script_path)

agrf <- read_agrf_sheet(agrf_sheet)

if (is.null(mlst_file)) {
  mlst_file <- find_mlst_file(consolidated_dir)
}
if (is.null(kleborate_file)) {
  kleborate_file <- find_kleborate_file(consolidated_dir)
}
if (is.null(fimtyper_file)) {
  fimtyper_file <- find_fimtyper_file(consolidated_dir)
}
if (is.null(abritamr_file)) {
  abritamr_file <- find_tool_merged_file(consolidated_dir, "abritamr")
}
if (is.null(plasmidfinder_file)) {
  plasmidfinder_file <- find_tool_merged_file(consolidated_dir, "plasmidfinder")
}
if (is.null(bracken_file)) {
  bracken_file <- find_tool_merged_file(consolidated_dir, "bracken")
}

message_path("MLST file", mlst_file)
message_path("Kleborate file", kleborate_file)
message_path("FimTyper file", fimtyper_file)
message_path("abritAMR file", abritamr_file)
message_path("PlasmidFinder file", plasmidfinder_file)
message_path("Bracken file", bracken_file)

mlst <- dedupe_by_sample(read_mlst_table(mlst_file))
kleborate <- dedupe_by_sample(read_kleborate_table(kleborate_file))
fimtyper <- dedupe_by_sample(read_fimtyper_table(fimtyper_file))
abritamr <- dedupe_by_sample(read_generic_tool_table(abritamr_file, "abritamr_"))
plasmidfinder <- dedupe_by_sample(read_generic_tool_table(plasmidfinder_file, "plasmidfinder_"))
bracken <- dedupe_by_sample(read_bracken_table(bracken_file))
result_samples <- collect_result_samples(mlst, kleborate, fimtyper, abritamr, plasmidfinder, bracken)

if (is.null(result_samples) || !nrow(result_samples)) {
  stop(
    "No samples were found in the consolidated result tables under --consolidated-dir.",
    call. = FALSE
  )
}

left_join_base <- function(x, y, by = "sample") {
  if (is.null(y) || !nrow(y)) {
    return(x)
  }

  idx <- match(x[[by]], y[[by]])
  add_cols <- setdiff(names(y), by)
  for (col in add_cols) {
    x[[col]] <- y[[col]][idx]
  }
  x
}

find_coverage_summary <- function(root) {
  candidates <- c(
    file.path(root, "coverage_summary.tsv"),
    file.path(root, "results_main", "merged-results", "coverage_summary.tsv")
  )
  candidates <- candidates[file.exists(candidates)]
  if (!length(candidates)) {
    return(NULL)
  }
  dat <- read_table_flex(candidates[[1L]])
  names(dat) <- tolower(gsub("[^A-Za-z0-9]+", "_", names(dat)))
  if (!"sample" %in% names(dat)) {
    return(NULL)
  }
  keep <- intersect(c("sample", "coverage_x", "low_coverage"), names(dat))
  if (length(keep) < 2L) {
    return(NULL)
  }
  dat[keep]
}

merged <- result_samples
merged <- left_join_base(merged, agrf, by = "sample")
if (!"Sample name" %in% names(merged)) {
  merged[["Sample name"]] <- merged$sample
}
missing_sample_name <- is.na(merged[["Sample name"]]) | !nzchar(trimws(as.character(merged[["Sample name"]])))
merged[["Sample name"]][missing_sample_name] <- merged$sample[missing_sample_name]
merged <- left_join_base(merged, mlst, by = "sample")
merged <- left_join_base(merged, kleborate, by = "sample")
merged <- left_join_base(merged, fimtyper, by = "sample")
merged <- left_join_base(merged, abritamr, by = "sample")
merged <- left_join_base(merged, plasmidfinder, by = "sample")
merged <- left_join_base(merged, bracken, by = "sample")
merged <- left_join_base(merged, find_coverage_summary(consolidated_dir), by = "sample")
merged <- flag_review_columns(merged)

preferred_order <- c(
  "Tube or well number",
  "Sample name",
  "Comments",
  "Concentration (ng/ul)",
  "A260:280",
  "A260:230",
  "Volume  (ul)",
  "mlst_scheme",
  "mlst_st",
  "mlst_profile",
  "kleborate_species",
  "kleborate_species_match",
  "kleborate_st",
  "kleborate_virulence_score",
  "kleborate_resistance_score",
  "kleborate_k_locus",
  "kleborate_k_type",
  "kleborate_o_locus",
  "kleborate_o_type",
  "fimtyper_fimtype",
  "fimtyper_identity",
  "abritamr_beta_lactam",
  "abritamr_esbl",
  "abritamr_carbapenemase",
  "abritamr_quinolone",
  "abritamr_sulfonamide",
  "plasmidfinder_replicon",
  "plasmidfinder_plasmid",
  "bracken_primary_species",
  "bracken_primary_species_abundance",
  "bracken_secondary_species",
  "bracken_secondary_species_abundance",
  "bracken_unclassified_abundance"
)

# Review/QC columns always sit at the very end of the sheet, after every tool
# block. `coverage_x` / `low_coverage` are the input-read coverage flag joined from
# the consolidated coverage_summary.tsv (present only when that table exists).
# `mlst_review_note` is appended downstream by run_review_mlst_from_tsv.sh (already
# last there); it is listed for robustness in case it ever reaches this stage. These
# are excluded from tool grouping so, e.g., `mlst_canonical_genus` does not fold into
# the MLST block mid-sheet.
review_tail_cols <- c(
  "review_required",
  "review_reason",
  "coverage_x",
  "low_coverage",
  "mlst_canonical_genus",
  "phenotype_canonical_genus",
  "mlst_review_note"
)

tail_cols <- intersect(review_tail_cols, names(merged))

# Order the columns so every tool's columns form ONE contiguous block. For each tool
# (in tool_prefix_order), its `preferred_order` columns come first (in that order),
# then any extra columns it emitted (e.g. abritamr drug-class columns that vary per
# run) in insertion order. Non-tool (metadata) columns lead; review/QC columns tail.
# The previous "preferred columns up front, everything else grouped after" split a
# tool whenever it had both listed and unlisted columns (e.g. abritamr around bracken).
tool_prefix_order <- c(
  "mlst_",
  "kleborate_",
  "fimtyper_",
  "abritamr_",
  "plasmidfinder_",
  "bracken_"
)
col_tool_rank <- function(col) {
  hit <- which(vapply(tool_prefix_order, function(p) startsWith(col, p), logical(1)))
  if (length(hit)) hit[[1L]] else NA_integer_
}

# All columns to order, minus the internal `sample` key (display uses "Sample name")
# and the review tail (kept out of tool grouping, appended at the very end).
orderable <- setdiff(names(merged), c("sample", tail_cols))
tool_rank <- vapply(orderable, col_tool_rank, integer(1))
pref_pos <- seq_along(preferred_order)
names(pref_pos) <- preferred_order

# Metadata columns (no tool prefix): preferred ones in preferred_order, then the rest.
meta_cols <- orderable[is.na(tool_rank)]
meta_pref <- intersect(preferred_order, meta_cols)
meta_cols <- c(meta_pref, setdiff(meta_cols, meta_pref))

# Per-tool blocks: preferred columns first (by preferred_order), then extras.
tool_block <- character(0)
for (ti in seq_along(tool_prefix_order)) {
  cols_t <- orderable[!is.na(tool_rank) & tool_rank == ti]
  if (!length(cols_t)) next
  pr <- pref_pos[cols_t]
  ord <- order(ifelse(is.na(pr), Inf, pr), seq_along(cols_t))
  tool_block <- c(tool_block, cols_t[ord])
}

merged <- merged[c(meta_cols, tool_block, tail_cols)]

write_tsv_flex(merged, output_file)
message("Wrote merged table: ", normalizePath(output_file, winslash = "/", mustWork = FALSE))

review_rows <- merged[merged$review_required == "yes", , drop = FALSE]
review_file <- review_output_path(output_file)
write_tsv_flex(review_rows, review_file)
message("Wrote review-required table: ", normalizePath(review_file, winslash = "/", mustWork = FALSE))

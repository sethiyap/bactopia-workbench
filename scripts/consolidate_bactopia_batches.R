#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)

usage <- function() {
  cat(
    "Usage:\n",
    "  Rscript scripts/consolidate_bactopia_batches.R",
    " --results-root <dir>",
    " --batch-prefix <prefix>",
    " --output-dir <dir>\n",
    sep = ""
  )
}

parse_args <- function(args) {
  if (length(args) == 0L || length(args) %% 2L != 0L) {
    usage()
    stop("Arguments must be supplied as --key value pairs.", call. = FALSE)
  }

  out <- list()
  i <- 1L
  while (i <= length(args)) {
    key <- args[[i]]
    value <- args[[i + 1L]]

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

results_root <- opts[["results-root"]]
batch_prefix <- opts[["batch-prefix"]]
output_dir <- opts[["output-dir"]]

if (is.null(results_root) || !dir.exists(results_root)) {
  stop("`--results-root` must point to an existing directory.", call. = FALSE)
}

if (is.null(batch_prefix) || !nzchar(batch_prefix)) {
  stop("`--batch-prefix` is required.", call. = FALSE)
}

if (is.null(output_dir) || !nzchar(output_dir)) {
  stop("`--output-dir` is required.", call. = FALSE)
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

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

normalize_sample_token <- function(x) {
  x <- trimws(as.character(x))
  x[nchar(x) == 0L] <- NA_character_
  sub("\\.(fna|fa|fasta)(\\.gz)?$", "", x, ignore.case = TRUE)
}

read_mlst_table <- function(path) {
  ext <- tolower(tools::file_ext(path))

  if (ext == "csv") {
    dat <- read_table_flex(path)
    if ("sample_name" %in% names(dat) && !"sample" %in% names(dat)) {
      names(dat)[names(dat) == "sample_name"] <- "sample"
    }
    if (!"sample" %in% names(dat)) {
      return(dat)
    }
    dat$sample <- normalize_sample_token(dat$sample)
    if ("sequence_type" %in% names(dat) && !"st" %in% names(dat)) {
      names(dat)[names(dat) == "sequence_type"] <- "st"
    }
    locus_cols <- setdiff(names(dat), c("sample", "scheme", "st", "batch_name", "source_file"))
    if (length(locus_cols)) {
      dat$profile <- apply(dat[locus_cols], 1L, function(row) {
        vals <- trimws(as.character(row))
        vals <- vals[nzchar(vals) & !is.na(vals)]
        paste(vals, collapse = " ")
      })
    } else {
      dat$profile <- NA_character_
    }
    keep <- intersect(c("sample", "scheme", "st", "profile"), names(dat))
    return(dat[keep])
  }

  lines <- readLines(path, warn = FALSE)
  if (!length(lines)) {
    return(data.frame(stringsAsFactors = FALSE))
  }

  tokens <- unlist(strsplit(paste(lines, collapse = " "), "[[:space:]]+"))
  tokens <- tokens[nzchar(tokens)]
  if (!length(tokens)) {
    return(data.frame(stringsAsFactors = FALSE))
  }

  is_sample_token <- function(x) {
    grepl("^[0-9]{2}GNB-[0-9]+R?\\.(fna|fa|fasta)(\\.gz)?$", x, ignore.case = TRUE)
  }
  is_batch_token <- function(x) grepl("^[[:alnum:]_]+_[0-9]{3}$", x)
  is_path_token <- function(x) grepl("^/", x)
  is_st_token <- function(x) grepl("^[0-9]+$", x) || identical(x, "-")

  sample_idx <- which(vapply(tokens, is_sample_token, logical(1)))
  if (!length(sample_idx)) {
    return(read_table_flex(path))
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

    sample <- normalize_sample_token(rec[[1L]])
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
        !vapply(profile_tokens, is_batch_token, logical(1)) &
        !vapply(profile_tokens, is_path_token, logical(1))
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
    return(data.frame(stringsAsFactors = FALSE))
  }

  out <- do.call(rbind, rows)
  out <- out[!is.na(out$sample) & !duplicated(out$sample), , drop = FALSE]
  rownames(out) <- NULL
  out
}

write_tsv_flex <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)

  if (requireNamespace("readr", quietly = TRUE)) {
    readr::write_tsv(x, path, na = "")
    return(invisible(path))
  }

  utils::write.table(x, file = path, sep = "\t", row.names = FALSE, quote = FALSE, na = "")
  invisible(path)
}

bind_rows_fill <- function(dfs) {
  dfs <- Filter(function(x) !is.null(x) && nrow(x) > 0L, dfs)
  if (!length(dfs)) {
    return(data.frame(stringsAsFactors = FALSE))
  }

  normalize_column_names <- function(df) {
    nms <- names(df)
    if (is.null(nms)) {
      nms <- rep("", ncol(df))
    }
    nms[is.na(nms)] <- ""
    nms <- trimws(nms)
    blank_idx <- which(!nzchar(nms))
    if (length(blank_idx)) {
      nms[blank_idx] <- paste0("unnamed_col_", seq_along(blank_idx))
    }
    names(df) <- make.unique(nms, sep = "_")
    df
  }

  dfs <- lapply(dfs, normalize_column_names)
  all_names <- unique(unlist(lapply(dfs, names), use.names = FALSE))
  aligned <- lapply(dfs, function(df) {
    missing <- setdiff(all_names, names(df))
    for (col in missing) {
      df[[col]] <- NA
    }
    df[, all_names, drop = FALSE]
  })

  out <- do.call(rbind, aligned)
  rownames(out) <- NULL
  out
}

sanitize_sheet_name <- function(x, used) {
  x <- gsub("[\\\\/?*\\[\\]:]", "_", x)
  x <- gsub("_+", "_", x)
  x <- sub("^_+", "", x)
  x <- substr(x, 1L, 31L)
  if (!nzchar(x)) {
    x <- "sheet"
  }

  candidate <- x
  i <- 1L
  while (candidate %in% used) {
    suffix <- paste0("_", i)
    candidate <- paste0(substr(x, 1L, max(1L, 31L - nchar(suffix))), suffix)
    i <- i + 1L
  }
  candidate
}

find_batch_dirs <- function(results_root, batch_prefix) {
  candidates <- list.dirs(results_root, recursive = FALSE, full.names = TRUE)
  pattern <- paste0("^", gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", batch_prefix), "_[0-9]+$")
  keep <- candidates[
    grepl(pattern, basename(candidates)) &
      vapply(candidates, function(x) !is.null(find_main_merged_dir(x)), logical(1))
  ]
  keep[order(basename(keep))]
}

find_latest_merged_dir <- function(parent_dir) {
  direct_dir <- file.path(parent_dir, "merged-results")
  if (dir.exists(direct_dir)) {
    return(direct_dir)
  }

  runs_root <- file.path(parent_dir, "bactopia-runs")
  if (!dir.exists(runs_root)) {
    return(NULL)
  }

  run_dirs <- list.dirs(runs_root, recursive = FALSE, full.names = TRUE)
  if (!length(run_dirs)) {
    return(NULL)
  }

  merged_dirs <- run_dirs[dir.exists(file.path(run_dirs, "merged-results"))]
  if (!length(merged_dirs)) {
    return(NULL)
  }

  info <- file.info(merged_dirs)
  mtimes <- info$mtime

  if (all(is.na(mtimes))) {
    merged_dirs <- merged_dirs[order(basename(merged_dirs), decreasing = TRUE)]
  } else {
    mtimes[is.na(mtimes)] <- as.POSIXct("1970-01-01", tz = "UTC")
    merged_dirs <- merged_dirs[order(mtimes, basename(merged_dirs), decreasing = TRUE)]
  }

  file.path(merged_dirs[[1L]], "merged-results")
}

find_main_merged_dir <- function(batch_dir) {
  find_latest_merged_dir(file.path(batch_dir, "results_main"))
}

find_tool_merged_dir <- function(tool_results_dir) {
  find_latest_merged_dir(tool_results_dir)
}

find_sample_level_tool_tables <- function(tool_run_dir, tool_name) {
  pattern <- "\\.(tsv|csv|txt)$"
  excluded_patterns <- c(
    "^marker_gene_stats\\.(tsv|csv|txt)$",
    "^hmmer\\.tree\\.(tsv|csv|txt)$",
    "^bin_stats(\\.analyze|\\.tree|_ext)?\\.(tsv|csv|txt)$"
  )

  score_sample_level_file <- function(path, sample_name, tool_name) {
    base <- basename(path)
    score <- 0

    if (any(grepl(paste(excluded_patterns, collapse = "|"), base, ignore.case = TRUE))) {
      return(-Inf)
    }

    if (grepl(paste0("^", sample_name, "\\.(tsv|csv|txt)$"), base, ignore.case = TRUE)) {
      score <- score + 100
    }
    if (grepl(paste0("^", sample_name, "[._-]", tool_name, ".*\\.(tsv|csv|txt)$"), base, ignore.case = TRUE)) {
      score <- score + 90
    }
    if (grepl(paste0("^", tool_name, "\\.(tsv|csv|txt)$"), base, ignore.case = TRUE)) {
      score <- score + 80
    }
    if (grepl("^results\\.(tsv|csv|txt)$", base, ignore.case = TRUE)) {
      score <- score + 70
    }
    if (grepl(paste0(tool_name, ".*\\.(tsv|csv|txt)$"), base, ignore.case = TRUE)) {
      score <- score + 40
    }
    if (grepl(paste0("^", sample_name), base, ignore.case = TRUE)) {
      score <- score + 20
    }
    if (grepl("\\.summary\\.(tsv|csv|txt)$", base, ignore.case = TRUE)) {
      score <- score + 10
    }

    score
  }

  sample_dirs <- list.dirs(tool_run_dir, recursive = FALSE, full.names = TRUE)
  sample_dirs <- sample_dirs[basename(sample_dirs) != "bactopia-runs"]

  files <- unlist(lapply(sample_dirs, function(sample_dir) {
    sample_name <- basename(sample_dir)
    if (tool_name == "fimtyper") {
      candidates <- c(
        file.path(sample_dir, sample_name, "results_tab.txt"),
        file.path(sample_dir, sample_name, "results.txt")
      )
      candidates <- candidates[file.exists(candidates)]
      if (!length(candidates)) {
        return(character())
      }
      return(candidates[[1L]])
    }

    tool_dir <- file.path(sample_dir, "tools", tool_name)
    if (!dir.exists(tool_dir)) {
      return(character())
    }

    if (tool_name == "clermontyping") {
      candidates <- list.files(tool_dir, pattern = "\\.phylogroups\\.(tsv|txt)$", recursive = TRUE, full.names = TRUE)
      if (length(candidates)) {
        return(candidates[[1L]])
      }
    }

    if (tool_name == "mlst") {
      candidates <- c(
        file.path(tool_dir, paste0(sample_name, ".tsv")),
        file.path(tool_dir, paste0(sample_name, ".txt")),
        file.path(tool_dir, "results.tsv"),
        file.path(tool_dir, "mlst.tsv")
      )
      candidates <- candidates[file.exists(candidates)]
      if (length(candidates)) {
        return(candidates[[1L]])
      }
    }

    if (tool_name == "bracken") {
      exact_candidates <- c(
        file.path(tool_dir, paste0(sample_name, ".bracken.abundances.txt")),
        file.path(tool_dir, "bracken.abundances.txt")
      )
      exact_candidates <- exact_candidates[file.exists(exact_candidates)]
      if (length(exact_candidates)) {
        return(exact_candidates[[1L]])
      }

      preferred_patterns <- c("\\.bracken\\.abundances\\.txt$")
      for (preferred_pattern in preferred_patterns) {
        candidates <- list.files(tool_dir, pattern = preferred_pattern, recursive = TRUE, full.names = TRUE)
        if (length(candidates)) {
          return(candidates[[1L]])
        }
      }
    }

    candidates <- list.files(tool_dir, pattern = pattern, recursive = TRUE, full.names = TRUE)
    if (!length(candidates)) {
      return(character())
    }

    scores <- vapply(candidates, score_sample_level_file, numeric(1), sample_name = sample_name, tool_name = tool_name)
    finite_scores <- is.finite(scores)
    if (!any(finite_scores)) {
      return(character())
    }

    candidates <- candidates[finite_scores]
    scores <- scores[finite_scores]
    candidates[[which.max(scores)]]
  }), use.names = FALSE)

  # unlist() over an empty/all-empty list yields NULL, and order(NULL) errors with
  # "argument 1 is not a vector". Return an empty character vector instead so the
  # caller falls back to the merged-dir path (and, ultimately, reports the tool as
  # having no results) rather than aborting the whole consolidation.
  if (!length(files)) {
    return(character())
  }
  files[order(files)]
}

sample_name_from_tool_path <- function(path) {
  parts <- strsplit(normalizePath(path, winslash = "/", mustWork = FALSE), "/", fixed = TRUE)[[1L]]
  tool_idx <- match("tools", parts)

  if (!is.na(tool_idx) && tool_idx >= 2L) {
    return(parts[[tool_idx - 1L]])
  }

  basename(dirname(dirname(dirname(path))))
}

normalize_sample_level_basename <- function(path, tool_name) {
  paste0(tool_name, "_merged.tsv")
}

collect_tool_tables <- function(tool_parent_dir, batch_name, tool_files_by_key, tool_batch_names_by_key) {
  if (!dir.exists(tool_parent_dir)) {
    return(list(
      tool_files_by_key = tool_files_by_key,
      tool_batch_names_by_key = tool_batch_names_by_key
    ))
  }

  tool_run_dirs <- list.dirs(tool_parent_dir, recursive = FALSE, full.names = TRUE)
  tool_run_dirs <- tool_run_dirs[grepl("^results_", basename(tool_run_dirs))]

  for (tool_run_dir in tool_run_dirs) {
    tool_name <- sub("^results_", "", basename(tool_run_dir))
    sample_level_files <- find_sample_level_tool_tables(tool_run_dir, tool_name)
    if (length(sample_level_files)) {
      for (file in sample_level_files) {
        key <- paste(tool_name, normalize_sample_level_basename(file, tool_name), sep = "::")
        tool_files_by_key[[key]] <- c(tool_files_by_key[[key]], file)
        tool_batch_names_by_key[[key]] <- c(tool_batch_names_by_key[[key]], batch_name)
      }
      next
    }

    candidate_dir <- find_tool_merged_dir(tool_run_dir)
    if (is.null(candidate_dir)) {
      candidate_dir <- tool_run_dir
    }

    for (file in find_tables(candidate_dir)) {
      key <- paste(tool_name, paste0(tool_name, "_merged.tsv"), sep = "::")
      tool_files_by_key[[key]] <- c(tool_files_by_key[[key]], file)
      tool_batch_names_by_key[[key]] <- c(tool_batch_names_by_key[[key]], batch_name)
    }
  }

  list(
    tool_files_by_key = tool_files_by_key,
    tool_batch_names_by_key = tool_batch_names_by_key
  )
}

find_tables <- function(path) {
  if (!dir.exists(path)) {
    return(character())
  }

  files <- list.files(
    path,
    pattern = "\\.(tsv|csv|txt)$",
    full.names = TRUE
  )
  files[order(basename(files))]
}

standardize_sample_column <- function(dat) {
  if (is.null(dat) || !nrow(dat)) {
    return(dat)
  }

  sample_col <- intersect(c("sample", "sample_name", "strain", "isolate", "x_sample", "samp"), names(dat))
  if (length(sample_col) && sample_col[[1L]] != "sample") {
    names(dat)[names(dat) == sample_col[[1L]]] <- "sample"
  }

  if ("sample" %in% names(dat)) {
    dat$sample <- normalize_sample_token(dat$sample)
    sample_idx <- match("sample", names(dat))
    other_idx <- setdiff(seq_along(dat), sample_idx)
    dat <- dat[c(sample_idx, other_idx)]
  }

  dat
}

read_fimtyper_result_tab <- function(path) {
  sample_name <- basename(dirname(path))
  lines <- readLines(path, warn = FALSE)
  lines <- trimws(lines)
  lines <- lines[nzchar(lines)]

  if (!length(lines)) {
    return(data.frame(
      sample = sample_name,
      fimtype = NA_character_,
      identity = NA_character_,
      query_hsp = NA_character_,
      contig = NA_character_,
      position = NA_character_,
      accession = NA_character_,
      stringsAsFactors = FALSE
    ))
  }

  header_idx <- which(grepl("^Fimtype\\s+Identity\\s+Query/HSP", lines, ignore.case = TRUE))
  if (!length(header_idx) || header_idx[[1L]] >= length(lines)) {
    return(data.frame(
      sample = sample_name,
      fimtype = NA_character_,
      identity = NA_character_,
      query_hsp = NA_character_,
      contig = NA_character_,
      position = NA_character_,
      accession = NA_character_,
      stringsAsFactors = FALSE
    ))
  }

  data_line <- lines[[header_idx[[1L]] + 1L]]
  fields <- strsplit(data_line, "[[:space:]]+", perl = TRUE)[[1L]]
  fields <- fields[nzchar(fields)]

  out <- data.frame(
    sample = sample_name,
    fimtype = if (length(fields) >= 1L) fields[[1L]] else NA_character_,
    identity = if (length(fields) >= 2L) fields[[2L]] else NA_character_,
    query_hsp = if (length(fields) >= 3L) fields[[3L]] else NA_character_,
    contig = if (length(fields) >= 4L) fields[[4L]] else NA_character_,
    position = if (length(fields) >= 5L) fields[[5L]] else NA_character_,
    accession = if (length(fields) >= 6L) paste(fields[6:length(fields)], collapse = " ") else NA_character_,
    stringsAsFactors = FALSE
  )

  out
}

read_bracken_summary_table <- function(path) {
  sample_name <- sample_name_from_tool_path(path)
  dat <- read_table_flex(path)

  empty_row <- function() {
    data.frame(
      sample = sample_name,
      bracken_primary_species = NA_character_,
      bracken_primary_species_abundance = NA_real_,
      bracken_secondary_species = "No secondary abundance > 1%",
      bracken_secondary_species_abundance = NA_real_,
      bracken_unclassified_abundance = NA_real_,
      stringsAsFactors = FALSE
    )
  }

  if (is.null(dat) || !nrow(dat)) {
    return(empty_row())
  }

  names(dat) <- tolower(gsub("[^A-Za-z0-9]+", "_", names(dat)))

  name_col <- intersect(c("name", "scientific_name", "taxon_name"), names(dat))
  abundance_col <- intersect(
    c("fraction_total_reads", "fraction", "abundance", "relative_abundance"),
    names(dat)
  )
  level_col <- intersect(c("taxonomy_lvl", "taxonomy_level", "level"), names(dat))
  est_reads_col <- intersect(c("new_est_reads", "reads", "estimated_reads"), names(dat))

  if (!length(name_col)) {
    return(empty_row())
  }

  dat[[name_col[[1L]]]] <- trimws(as.character(dat[[name_col[[1L]]]]))
  level_values <- rep(NA_character_, nrow(dat))
  if (length(level_col)) {
    level_values <- trimws(as.character(dat[[level_col[[1L]]]]))
  }

  if (length(abundance_col)) {
    abundance_values <- suppressWarnings(as.numeric(dat[[abundance_col[[1L]]]]))
  } else if (length(est_reads_col)) {
    est_reads <- suppressWarnings(as.numeric(dat[[est_reads_col[[1L]]]]))
    total_reads <- sum(est_reads, na.rm = TRUE)
    abundance_values <- if (is.finite(total_reads) && total_reads > 0) est_reads / total_reads else rep(NA_real_, length(est_reads))
  } else {
    abundance_values <- rep(NA_real_, nrow(dat))
  }
  dat$.__abundance__ <- abundance_values

  is_unclassified <- grepl("^unclassified$", dat[[name_col[[1L]]]], ignore.case = TRUE) |
    grepl("^u$", level_values, ignore.case = TRUE)
  unclassified_abundance <- suppressWarnings(max(dat$.__abundance__[is_unclassified], na.rm = TRUE))
  if (!is.finite(unclassified_abundance)) {
    unclassified_abundance <- NA_real_
  }

  species_rows <- rep(TRUE, nrow(dat))
  if (length(level_col)) {
    species_rows <- grepl("^s$", level_values, ignore.case = TRUE)
  }
  classified <- dat[species_rows & !is_unclassified, , drop = FALSE]
  if (!nrow(classified)) {
    classified <- dat[!is_unclassified, , drop = FALSE]
  }
  if (!nrow(classified)) {
    out <- empty_row()
    out$bracken_unclassified_abundance <- unclassified_abundance
    return(out)
  }

  classified <- classified[order(classified$.__abundance__, decreasing = TRUE, na.last = TRUE), , drop = FALSE]
  primary_name <- classified[[name_col[[1L]]]][[1L]]
  primary_abundance <- classified$.__abundance__[[1L]]

  secondary_name <- "No secondary abundance > 1%"
  secondary_abundance <- NA_real_
  if (nrow(classified) >= 2L) {
    candidate_abundance <- classified$.__abundance__[[2L]]
    if (is.finite(candidate_abundance) && candidate_abundance > 0.01) {
      secondary_name <- classified[[name_col[[1L]]]][[2L]]
      secondary_abundance <- candidate_abundance
    }
  }

  data.frame(
    sample = sample_name,
    bracken_primary_species = primary_name,
    bracken_primary_species_abundance = primary_abundance,
    bracken_secondary_species = secondary_name,
    bracken_secondary_species_abundance = secondary_abundance,
    bracken_unclassified_abundance = unclassified_abundance,
    stringsAsFactors = FALSE
  )
}

empty_output_template <- function(files, out_path) {
  out_base <- basename(out_path)

  if (identical(out_base, "mlst_merged.tsv") || identical(out_base, "mlst.tsv") || any(grepl("(^|/)results_mlst(/|$)", files))) {
    return(data.frame(
      sample = character(),
      scheme = character(),
      st = character(),
      profile = character(),
      batch_name = character(),
      source_file = character(),
      stringsAsFactors = FALSE
    ))
  }

  if (identical(out_base, "bracken_merged.tsv") || any(grepl("(^|/)results_bracken(/|$)", files))) {
    return(data.frame(
      sample = character(),
      bracken_primary_species = character(),
      bracken_primary_species_abundance = numeric(),
      bracken_secondary_species = character(),
      bracken_secondary_species_abundance = numeric(),
      bracken_unclassified_abundance = numeric(),
      batch_name = character(),
      source_file = character(),
      stringsAsFactors = FALSE
    ))
  }

  data.frame(stringsAsFactors = FALSE)
}

build_tool_processing_log <- function(tool_files_by_key, tool_batch_names_by_key) {
  if (!length(tool_files_by_key)) {
    return(data.frame(
      tool_name = character(),
      consolidated_file = character(),
      input_files_processed = integer(),
      unique_batches = integer(),
      input_mode = character(),
      stringsAsFactors = FALSE
    ))
  }

  rows <- lapply(sort(names(tool_files_by_key)), function(key) {
    parts <- strsplit(key, "::", fixed = TRUE)[[1L]]
    tool_name <- parts[[1L]]
    base <- parts[[2L]]
    files <- tool_files_by_key[[key]]
    batches <- tool_batch_names_by_key[[key]]
    input_mode <- if (all(
      grepl("/tools/[^/]+/.+\\.(tsv|csv|txt)$", files) |
      grepl("/results_fimtyper/[^/]+/[^/]+/results_(tab|txt)\\.txt$", files)
    )) {
      "sample_level"
    } else {
      "merged_results_fallback"
    }

    data.frame(
      tool_name = tool_name,
      consolidated_file = paste0(tools::file_path_sans_ext(base), ".tsv"),
      input_files_processed = length(files),
      unique_batches = length(unique(batches)),
      input_mode = input_mode,
      stringsAsFactors = FALSE
    )
  })

  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

parse_sample_level_tool_table <- function(path) {
  dat <- read_table_flex(path)
  if (is.null(dat) || !nrow(dat)) {
    return(dat)
  }

  names(dat) <- tolower(gsub("[^A-Za-z0-9]+", "_", names(dat)))
  sample_col <- intersect(c("sample", "sample_name", "strain", "isolate", "x_sample", "samp"), names(dat))
  sample_name <- sample_name_from_tool_path(path)

  if (length(sample_col)) {
    names(dat)[names(dat) == sample_col[[1L]]] <- "sample"
  } else {
    dat$sample <- sample_name
  }

  dat$sample <- trimws(as.character(dat$sample))
  replace_with_path_sample <- is.na(dat$sample) | !nzchar(dat$sample) | dat$sample == "results"
  dat$sample[replace_with_path_sample] <- sample_name

  standardize_sample_column(dat)
}

combine_table_group <- function(files, batch_names, out_path) {
  pieces <- vector("list", length(files))

  for (i in seq_along(files)) {
    if (grepl("(^|/)results_mlst(/|$)", files[[i]]) && grepl("^mlst\\.(tsv|txt|csv)$", basename(files[[i]]), ignore.case = TRUE)) {
      dat <- read_mlst_table(files[[i]])
    } else if (grepl("/tools/mlst/[^/]+\\.(tsv|txt|csv)$", files[[i]])) {
      dat <- read_mlst_table(files[[i]])
    } else if (grepl("/tools/bracken/[^/]+\\.bracken(\\.abundances)?\\.(tsv|txt|csv)$", files[[i]])) {
      dat <- read_bracken_summary_table(files[[i]])
    } else if (grepl("/results_fimtyper/[^/]+/[^/]+/results_(tab|txt)\\.txt$", files[[i]])) {
      dat <- read_fimtyper_result_tab(files[[i]])
    } else if (grepl("/tools/[^/]+/.+\\.(tsv|csv|txt)$", files[[i]])) {
      dat <- parse_sample_level_tool_table(files[[i]])
    } else {
      dat <- read_table_flex(files[[i]])
    }
    dat <- standardize_sample_column(dat)
    dat[["batch_name"]] <- rep(batch_names[[i]], nrow(dat))
    dat[["source_file"]] <- rep(
      normalizePath(files[[i]], winslash = "/", mustWork = FALSE),
      nrow(dat)
    )
    pieces[[i]] <- dat
  }

  combined <- bind_rows_fill(pieces)
  combined <- standardize_sample_column(combined)
  if (!nrow(combined) && !ncol(combined)) {
    combined <- empty_output_template(files, out_path)
  }
  write_tsv_flex(combined, out_path)
  combined
}

build_project_summary <- function(batch_dirs) {
  rows <- lapply(batch_dirs, function(batch_dir) {
    batch_name <- basename(batch_dir)
    main_merged_dir <- find_main_merged_dir(batch_dir)
    main_results_dir <- file.path(batch_dir, "results_main")
    samples_path <- file.path(main_merged_dir, "samples.tsv")
    if (!file.exists(samples_path)) {
      samples_path <- file.path(main_merged_dir, "samples.csv")
    }

    sample_count <- NA_integer_
    if (file.exists(samples_path)) {
      dat <- tryCatch(read_table_flex(samples_path), error = function(e) NULL)
      if (!is.null(dat) && nrow(dat) > 0L) {
        sample_count <- nrow(dat)
      }
    }

    if (is.na(sample_count) && dir.exists(main_results_dir)) {
      sample_dirs <- list.dirs(main_results_dir, recursive = FALSE, full.names = FALSE)
      sample_dirs <- sample_dirs[nzchar(sample_dirs) & sample_dirs != "bactopia-runs"]
      sample_count <- length(sample_dirs)
    }

    data.frame(
      batch_name = batch_name,
      batch_dir = normalizePath(batch_dir, winslash = "/", mustWork = FALSE),
      sample_count = sample_count,
      stringsAsFactors = FALSE
    )
  })

  do.call(rbind, rows)
}

merge_by_sample <- function(dfs) {
  dfs <- Filter(function(x) !is.null(x) && nrow(x) > 0L && "sample" %in% names(x), dfs)
  if (!length(dfs)) {
    return(data.frame(stringsAsFactors = FALSE))
  }

  out <- dfs[[1L]]
  if (length(dfs) == 1L) {
    return(out)
  }

  for (i in 2:length(dfs)) {
    out <- merge(out, dfs[[i]], by = "sample", all = TRUE, sort = FALSE)
  }

  out
}

standardize_main_component <- function(dat, file_stub) {
  names(dat) <- tolower(gsub("[^A-Za-z0-9]+", "_", names(dat)))

  if (file_stub == "samples" && "sample" %in% names(dat)) {
    keep <- intersect(c("sample", "species", "batch_name"), names(dat))
    return(dat[keep])
  }

  if (file_stub == "assembly_summary" && "sample" %in% names(dat)) {
    rename_map <- c(
      total_length = "assembly_size",
      genome_length = "assembly_size",
      assembly_length = "assembly_size",
      contigs = "contig_count",
      number_of_contigs = "contig_count"
    )
    for (from in names(rename_map)) {
      if (from %in% names(dat) && !rename_map[[from]] %in% names(dat)) {
        names(dat)[names(dat) == from] <- rename_map[[from]]
      }
    }
    keep <- intersect(c("sample", "assembly_size", "contig_count", "n50", "batch_name"), names(dat))
    return(dat[keep])
  }

  if (file_stub == "mlst" && "sample" %in% names(dat)) {
    if ("sample_name" %in% names(dat) && !"sample" %in% names(dat)) {
      names(dat)[names(dat) == "sample_name"] <- "sample"
    }
    st_col <- intersect(c("st", "sequence_type"), names(dat))
    keep <- c("sample", st_col[1], "batch_name")
    keep <- keep[!is.na(keep)]
    return(dat[keep])
  }

  if (file_stub == "amr" && "sample" %in% names(dat)) {
    gene_col <- intersect(c("gene", "amr_gene", "resistance_gene"), names(dat))
    if (!length(gene_col)) {
      counts <- stats::aggregate(sample ~ sample, data = dat, FUN = length)
      names(counts)[2L] <- "amr_gene_count"
      return(counts)
    }
    counts <- stats::aggregate(
      dat[[gene_col[1L]]],
      by = list(sample = dat$sample),
      FUN = function(x) sum(!is.na(x) & trimws(as.character(x)) != "")
    )
    names(counts)[2L] <- "amr_gene_count"
    return(counts)
  }

  if (file_stub == "plasmid" && "sample" %in% names(dat)) {
    plasmid_col <- intersect(c("replicon", "plasmid", "plasmid_type"), names(dat))
    if (!length(plasmid_col)) {
      counts <- stats::aggregate(sample ~ sample, data = dat, FUN = length)
      names(counts)[2L] <- "plasmid_count"
      return(counts)
    }
    counts <- stats::aggregate(
      dat[[plasmid_col[1L]]],
      by = list(sample = dat$sample),
      FUN = function(x) sum(!is.na(x) & trimws(as.character(x)) != "")
    )
    names(counts)[2L] <- "plasmid_count"
    return(counts)
  }

  dat
}

batch_dirs <- find_batch_dirs(results_root, batch_prefix)
if (!length(batch_dirs)) {
  stop("No batch result directories were found under: ", results_root, call. = FALSE)
}

message("Discovered ", length(batch_dirs), " batch result directories")

project_summary <- build_project_summary(batch_dirs)
write_tsv_flex(project_summary, file.path(output_dir, "project_summary.tsv"))

main_files_by_base <- list()
main_batch_names_by_base <- list()
tool_files_by_key <- list()
tool_batch_names_by_key <- list()

for (batch_dir in batch_dirs) {
  batch_name <- basename(batch_dir)
  main_merged_dir <- find_main_merged_dir(batch_dir)

  for (file in find_tables(main_merged_dir)) {
    base <- basename(file)
    main_files_by_base[[base]] <- c(main_files_by_base[[base]], file)
    main_batch_names_by_base[[base]] <- c(main_batch_names_by_base[[base]], batch_name)
  }

  for (suffix in c("_tools", "_kleborate", "_fimtyper", "_bracken_only")) {
    tool_parent_dir <- file.path(results_root, paste0(batch_name, suffix))
    collected <- collect_tool_tables(
      tool_parent_dir,
      batch_name,
      tool_files_by_key,
      tool_batch_names_by_key
    )
    tool_files_by_key <- collected$tool_files_by_key
    tool_batch_names_by_key <- collected$tool_batch_names_by_key
  }
}

# If no batch produced any main or per-sample tool tables, the upstream stage
# emitted nothing to consolidate (typically every sample failed Bactopia's QC, so
# no assemblies were made and each results_<tool>/ holds only bactopia-runs/). Fail
# with a clear explanation instead of writing empty outputs and reporting success.
if (!length(main_files_by_base) && !length(tool_files_by_key)) {
  stop(
    "No per-sample results were found in any batch under '", results_root, "'. ",
    "Every results_<tool>/ contained only bactopia-runs/ (no sample outputs), which ",
    "usually means the assembly/QC stage produced nothing -- e.g. all samples failed ",
    "Bactopia's coverage / min-basepairs QC. Check the Bactopia stage logs and the ",
    "genome-size / QC settings before re-running consolidation.",
    call. = FALSE
  )
}

tool_processing_log <- build_tool_processing_log(tool_files_by_key, tool_batch_names_by_key)
write_tsv_flex(tool_processing_log, file.path(output_dir, "tool_processing_log.tsv"))

main_tables <- list()
for (base in sort(names(main_files_by_base))) {
  stub <- tools::file_path_sans_ext(base)
  out_path <- file.path(output_dir, "results_main", "merged-results", paste0(stub, ".tsv"))
  combined <- combine_table_group(main_files_by_base[[base]], main_batch_names_by_base[[base]], out_path)
  main_tables[[stub]] <- combined
}

tool_tables <- list()
for (key in sort(names(tool_files_by_key))) {
  parts <- strsplit(key, "::", fixed = TRUE)[[1L]]
  tool_name <- parts[[1L]]
  base <- parts[[2L]]
  stub <- tools::file_path_sans_ext(base)
  out_path <- file.path(output_dir, "tools", paste0("results_", tool_name), "merged-results", paste0(stub, ".tsv"))
  combined <- combine_table_group(tool_files_by_key[[key]], tool_batch_names_by_key[[key]], out_path)
  tool_tables[[paste0(tool_name, "__", stub)]] <- combined
}

summary_components <- list()
for (stub in c("samples", "assembly_summary", "mlst", "amr", "plasmid")) {
  if (!stub %in% names(main_tables)) {
    next
  }
  summary_components[[stub]] <- standardize_main_component(main_tables[[stub]], stub)
}

run_summary <- merge_by_sample(summary_components)
if (nrow(run_summary) > 0L) {
  write_tsv_flex(run_summary, file.path(output_dir, "results_main", "merged-results", "run_summary.tsv"))
}

message("TSV consolidation completed successfully.")
message("Combined text results written to: ", normalizePath(output_dir, winslash = "/", mustWork = FALSE))
if (nrow(tool_processing_log) > 0L) {
  message("Tool processing log written to: ", normalizePath(file.path(output_dir, "tool_processing_log.tsv"), winslash = "/", mustWork = FALSE))
}
message("Consolidation complete. This step writes TSV outputs only.")

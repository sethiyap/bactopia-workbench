# FimTyper container for bactopia-workbench.
#
# Provides the legacy CGE Perl FimTyper at the exact paths the pipeline calls
# (see bactopia_config/fimtyper.nf):
#   perl /usr/local/fimtyper/fimtyper.pl -d /usr/local/fimtyper/fimtyper_db ...
#
# Published to GHCR by .github/workflows/build-fimtyper.yml and consumed by the
# fimtyper.*.config files via a registry URI so Nextflow pulls it automatically.
#
# NOTE: FimTyper's Perl script drives NCBI BLAST. This image installs blast+
# (blastn). If the upstream fimtyper.pl expects legacy `blastall`, add a legacy
# BLAST 2.2.x layer (see the commented block below) and rebuild — the CI build and
# a test run are the source of truth.

FROM ubuntu:22.04

ARG FIMTYPER_REF=master
ARG FIMTYPER_DB_REF=master
ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="agar-bactopia-fimtyper" \
      org.opencontainers.image.description="CGE Perl FimTyper + database for bactopia-workbench" \
      org.opencontainers.image.source="https://github.com/sethiyap/bactopia-workbench" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN apt-get update && apt-get install -y --no-install-recommends \
        perl \
        ncbi-blast+ \
        git \
        ca-certificates \
        procps \
        gzip \
    && rm -rf /var/lib/apt/lists/*

# FimTyper tool + database at the paths fimtyper.nf hardcodes.
RUN git clone --depth 1 --branch "${FIMTYPER_REF}" \
        https://bitbucket.org/genomicepidemiology/fimtyper.git /usr/local/fimtyper \
    && git clone --depth 1 --branch "${FIMTYPER_DB_REF}" \
        https://bitbucket.org/genomicepidemiology/fimtyper_db.git /usr/local/fimtyper/fimtyper_db \
    && chmod -R a+rX /usr/local/fimtyper

# Some CGE fimtyper_db releases ship a build step to index the BLAST DB.
RUN if [ -f /usr/local/fimtyper/fimtyper_db/INSTALL.py ]; then \
        (cd /usr/local/fimtyper/fimtyper_db && python3 INSTALL.py 2>/dev/null || true); \
    fi

ENV PATH="/usr/local/fimtyper:${PATH}"

# ---------------------------------------------------------------------------
# If fimtyper.pl requires legacy `blastall` (BLAST 2.2.x) rather than blast+,
# uncomment and rebuild:
#
# RUN apt-get update && apt-get install -y --no-install-recommends wget \
#     && wget -q https://ftp.ncbi.nlm.nih.gov/blast/executables/legacy.NOTSUPPORTED/2.2.26/blast-2.2.26-x64-linux.tar.gz \
#     && tar -xzf blast-2.2.26-x64-linux.tar.gz -C /usr/local \
#     && ln -s /usr/local/blast-2.2.26/bin/blastall /usr/local/bin/blastall \
#     && ln -s /usr/local/blast-2.2.26/bin/formatdb /usr/local/bin/formatdb \
#     && rm -f blast-2.2.26-x64-linux.tar.gz && rm -rf /var/lib/apt/lists/*
# ---------------------------------------------------------------------------

WORKDIR /data
CMD ["perl", "/usr/local/fimtyper/fimtyper.pl", "-h"]

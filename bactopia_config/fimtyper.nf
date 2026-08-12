nextflow.enable.dsl=2

params.results_main = null
params.outdir = 'results_fimtyper'

if (!params.results_main) {
    error "Set --results_main to your Bactopia results_main directory"
}

assemblies_ch = Channel
    .fromPath("${params.results_main}/*/main/assembler/*.fna.gz", checkIfExists: true)
    .map { assembly ->
        def sample = assembly.baseName.replaceFirst(/\.fna$/, '')
        tuple(sample, assembly)
    }

// FimTyper resolves from one of two layouts:
//   - native: FIMTYPER_DIR points at a fimtyper checkout (fimtyper.pl +
//     fimtyper_db/), with FIMTYPER_ENV supplying BLAST on PATH. fimtyper.local.config
//     turns the container engine off in this mode.
//   - container: FIMTYPER_DIR unset, so the published image's bundled
//     /usr/local/fimtyper layout is used and the image is pulled as before.
// The container layout stays the fallback so existing container runs are unchanged.
fimtyperRoot = System.getenv('FIMTYPER_DIR') ?: '/usr/local/fimtyper'
fimtyperEnv  = System.getenv('FIMTYPER_ENV')

process FIMTYPER {
    tag "${sample}"
    publishDir params.outdir, mode: 'copy'

    cpus 1
    memory '4 GB'
    time '4h'

    input:
    tuple val(sample), path(assembly)

    output:
    path("${sample}")

    script:
    def envPath = fimtyperEnv ? "export PATH=\"${fimtyperEnv}/bin:\$PATH\"" : ''
    """
    ${envPath}
    mkdir -p ${sample}

    gunzip -c ${assembly} > ${sample}.fna

    perl ${fimtyperRoot}/fimtyper.pl \\
      -d ${fimtyperRoot}/fimtyper_db \\
      -i ${sample}.fna \\
      -k 95.00 \\
      -l 0.60 \\
      -o ${sample}/${sample}

    rm -f ${sample}.fna
    """
}

process FIMTYPER_MERGE {
    publishDir params.outdir, mode: 'copy'

    input:
    path sample_dirs

    output:
    path "fimtyper_summary.tsv"

    script:
    """
    printf "sample\tresult\n" > fimtyper_summary.tsv

    find . -mindepth 1 -maxdepth 1 -type d | sort | while read -r sample_dir; do
      sample=\$(basename "\$sample_dir")
      result_file="\$sample_dir/\$sample/results_tab.txt"

      if [[ -f "\$result_file" ]]; then
        result=\$(grep -v '^FimH type' "\$result_file" | grep -v '^Please contact curator' | paste -sd ' | ' -)
        [[ -z "\$result" ]] && result=\$(paste -sd ' | ' "\$result_file")
        printf "%s\t%s\n" "\$sample" "\$result" >> fimtyper_summary.tsv
      else
        printf "%s\t%s\n" "\$sample" "results_tab.txt missing" >> fimtyper_summary.tsv
      fi
    done
    """
}


workflow {
    fimtyper_out = FIMTYPER(assemblies_ch)
    FIMTYPER_MERGE(fimtyper_out.collect())
}

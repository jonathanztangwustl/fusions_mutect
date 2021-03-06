version 1.0

import "mutect2.wdl" as m2

# WDL tasks and workflow for investigating CH fusions with Terra
# Also runs mutect2 and deletion detection to search for mutations in subset of genes

# Samtools task
task samtools {
    input {
        File fusions_bed
        File subset_bed
        File full_cram
        File full_cram_crai
        File ref_fa
        File ref_fa_fai
    }
    Int cores = 1
    Float cram_size = size([full_cram, full_cram_crai, ref_fa, ref_fa_fai], "GB")
    Int runtime_size = 15 + round(cram_size)
    runtime {
        memory: "4GB"
        cpu: cores
        preemptible: 1
        docker: "quay.io/biocontainers/samtools:1.15.1--h1170115_0"
        disks: "local-disk ~{runtime_size} SSD"
        bootDiskSizeGb: runtime_size
    }
    command <<<
        set -o pipefail
        set -o errexit
        ln -s ~{full_cram} full.cram
        ln -s ~{full_cram_crai} full.cram.crai
        samtools view -b -L ~{fusions_bed} -M -T ~{ref_fa} -t ~{ref_fa_fai} -F 1028 -f 1 -q 30 -o fusions.bam full.cram
        samtools index fusions.bam
        samtools view -b -L ~{subset_bed} -M -T ~{ref_fa} -t ~{ref_fa_fai} -F 1028 -f 1 -o subset.bam full.cram
        samtools index -b subset.bam
        samtools flagstat full.cram > flagstat
    >>>
    output {
        File fusions_bam = "fusions.bam"
        File fusions_bam_bai = "fusions.bam.bai"
        File subset_bam = "subset.bam"
        File subset_bam_bai = "subset.bam.bai"
        File flagstat = "flagstat"
    }
}

# Fusions.py task
task fusions {
    input {
        File fusions_bam
        File fusions_bam_bai
        File ROIs
        File gene_ref_bed
    }
    Int cores = 1
    Float bam_size = size([fusions_bam, fusions_bam_bai], "GB")
    Int runtime_size = 10 + round(bam_size)
    runtime {
        memory: "4GB"
        cpu: cores
        preemptible: 1
        docker: "jonathanztangwustl/docker_fusions:0.1.5"
        disks: "local-disk ~{runtime_size} SSD"
        bootDiskSizeGb: runtime_size
    }
    command <<<
        ln -s ~{fusions_bam} fusions.bam
        ln -s ~{fusions_bam_bai} fusions.bam.bai
        fusions.py \
        fusions.bam \
        ~{ROIs} \
        ~{gene_ref_bed} \
        fusions_out.txt
    >>>
    output {
        File fusions_out = "fusions_out.txt"
    }
}

# CNV - Indexcov
task indexcov {
    input {
        File full_cram_crai
        File ref_fa_fai
    }
    Int cores = 1
    Float crai_size = size([full_cram_crai, ref_fa_fai], "GB")
    Int runtime_size = 15 + round(crai_size)
    runtime {
        memory: "4GB"
        cpu: cores
        preemptible: 1
        docker: "quay.io/biocontainers/goleft:0.2.4--0"
        disks: "local-disk ~{runtime_size} SSD"
        bootDiskSizeGb: runtime_size
    }
    command <<<
        goleft indexcov --extranormalize -d indexcov --fai ~{ref_fa_fai} ~{full_cram_crai}
        rm indexcov/*.html indexcov/*.png
        tar -cvf indexcov.tar indexcov/
        gzip indexcov.tar
    >>>
    output {
        File indexcov_out = "indexcov.tar.gz"
    }
}

# CNV - mosdepth
task mosdepth {
    input {
        File ref_fa
        File ref_fa_fai
        File full_cram
        File full_cram_crai
        File subset_mosdepth
    }
    Int cores = 1
    Float bam_size = size([full_cram, full_cram_crai, ref_fa, ref_fa_fai], "GB")
    Int runtime_size = 15 + round(bam_size)
    runtime {
        memory: "4GB"
        cpu: cores
        preemptible: 1
        docker: "quay.io/biocontainers/mosdepth:0.3.3--h37c5b7d_2"
        disks: "local-disk ~{runtime_size} SSD"
        bootDiskSizeGb: runtime_size
    }
    command <<<
        ln -s ~{full_cram} full.cram
        ln -s ~{full_cram_crai} full.cram.crai
        ln -s ~{ref_fa} ref.fa
        ln -s ~{ref_fa_fai} ref.fa.fai
        mkdir mosdepth
        mosdepth -b ~{subset_mosdepth} -n -f ref.fa mosdepth/cnv full.cram
        tar -cvf mosdepth.tar mosdepth/
        gzip mosdepth.tar
    >>>
    output {
        File mosdepth_out = "mosdepth.tar.gz"
    }
}

# Workflow to call samtools, fusions, mutations, and deletions
workflow fusions_mutations {
    input {
        File wf_fusions_bed
        File wf_full_cram
        File wf_full_cram_crai
        File wf_ROIs
        File wf_subset_bed
        File wf_subset_mosdepth
        File wf_gene_ref_bed
        File wf_ref_fa
        File wf_ref_fa_fai
        File wf_ref_dict
        File Mutect2_intervals
        Int Mutect2_scatter_count
        String Mutect2_gatk_docker
        File Mutect2_gatk_override
        Boolean Mutect2_run_funcotator
        File wf_subset_mosdepth
    }
    call indexcov {
        input:
        full_cram_crai=wf_full_cram_crai,
        ref_fa_fai=wf_ref_fa_fai
    }
    call mosdepth {
        input:
        ref_fa=wf_ref_fa,
        ref_fa_fai=wf_ref_fa_fai,
        full_cram=wf_full_cram,
        full_cram_crai=wf_full_cram_crai,
        subset_mosdepth=wf_subset_mosdepth
    }
    call samtools {
        input:
        fusions_bed=wf_fusions_bed,
        subset_bed=wf_subset_bed,
        full_cram=wf_full_cram,
        full_cram_crai=wf_full_cram_crai,
        ref_fa=wf_ref_fa,
        ref_fa_fai=wf_ref_fa_fai
    }
    call fusions {
        input:
        fusions_bam=samtools.fusions_bam,
        fusions_bam_bai=samtools.fusions_bam_bai,
        ROIs=wf_ROIs,
        gene_ref_bed=wf_gene_ref_bed
    }
    call m2.Mutect2{
        input:
        intervals=Mutect2_intervals,
        ref_fasta=wf_ref_fa,
        ref_fai=wf_ref_fa_fai,
        ref_dict=wf_ref_dict,
        tumor_reads=samtools.subset_bam,
        tumor_reads_index=samtools.subset_bam_bai,
        scatter_count=Mutect2_scatter_count,
        gatk_docker=Mutect2_gatk_docker,
        gatk_override=Mutect2_gatk_override,
        run_funcotator=Mutect2_run_funcotator
    }
    output {
        File fusions_bam = samtools.fusions_bam
        File fusions_bam_bai = samtools.fusions_bam_bai
        File flagstat = samtools.flagstat
        File fusions_out = fusions.fusions_out
        File subset_bam = samtools.subset_bam
        File subset_bam_bai = samtools.subset_bam_bai
        File filtered_vcf = Mutect2.filtered_vcf
        File filtered_vcf_idx = Mutect2.filtered_vcf_idx
        File indexcov_out = indexcov.indexcov_out
        File mosdepth_out = mosdepth.mosdepth_out
    }
}

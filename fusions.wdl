version 1.0

import "mutect2.wdl" as m2

# WDL tasks and workflow for investigating CH fusions with Terra
# Also runs mutect2 and deletion detection to search for DNMT3A mutations

# TODO items
# TODO: Complete CH Fusion workflow - complete
# TODO: Add DNMT3A mutation detection/Mutect2 - complete
# TODO: Code review/tidy - in progress
# TODO: Tweak samtools flags; tweak samtools for performance; tweak filenames - in progress
# TODO: New name for the workflow

# Samtools task for fusions.py
task samtools_fusions {
    input {
        File fusions_bed
        File full_wgs
        File full_wgs_idx
        File ref_fa
        File ref_fa_fai
    }
    Int cores = 1
    Float wgs_size = size([full_wgs], "GB")
    Int runtime_size = 4 + round(wgs_size)
    runtime {
        memory: "4GB"
        cpu: cores
        preemptible: 1
        docker: "chrisamiller/genomic-analysis:0.2"
        disks: "local-disk ~{runtime_size} SSD"
        bootDiskSizeGb: runtime_size
    }
    command <<<
        set -o pipefail
        set -o errexit
        ln -s ~{full_wgs} full.wgs
        ln -s ~{full_wgs_idx} full.wgs.idx
        samtools view -b -L ~{fusions_bed} -T ~{ref_fa} -t ~{ref_fa_fai} -o fusions.bam full.wgs
    >>>
    output {
        File fusions_bam = "fusions.bam"
    }
}

# Samtools task for mutect
task samtools_mutect {
    input {
        File dnmt3a_bed
        File full_wgs
        File full_wgs_idx
        File ref_fa
        File ref_fa_fai
    }
    Int cores = 1
    Float bam_size = size([full_wgs], "GB")
    Int runtime_size = 4 + round(bam_size)
    runtime {
        memory: "4GB"
        cpu: cores
        preemptible: 1
        docker: "chrisamiller/genomic-analysis:0.2"
        disks: "local-disk ~{runtime_size} SSD"
        bootDiskSizeGb: runtime_size
    }
    command <<<
        set -o pipefail
        set -o errexit
        ln -s ~{full_wgs} full.wgs
        ln -s ~{full_wgs_idx} full.wgs.idx
        samtools view -b -L ~{dnmt3a_bed} -T ~{ref_fa} -t ~{ref_fa_fai} -o dnmt3a.bam full.wgs
        samtools index -b dnmt3a.bam
    >>>
    output {
        File dnmt3a_bam = "dnmt3a.bam"
        File dnmt3a_bai = "dnmt3a.bam.bai"
    }
}

# Fusions.py task
task fusions {
    input {
        File fusions_py
        File fusions_bam
        File ROIs
        File gene_ref_bed
    }
    Int cores = 4
    Float bam_size = size([fusions_bam], "GB")
    Int runtime_size = 4 + round(bam_size)
    runtime {
        memory: "4GB"
        cpu: cores
        preemptible: 1
        docker: "chrisamiller/genomic-analysis:0.2"
        disks: "local-disk ~{runtime_size} SSD"
        bootDiskSizeGb: runtime_size
    }
    command <<<
        python \
        ~{fusions_py} \
        ~{fusions_bam} \
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
        File full_wgs_idx
        File ref_fa_fai
    }
    Int cores = 1
    Float idx_size = size([full_wgs_idx], "GB")
    Int runtime_size = 4 + round(idx_size)
    runtime {
        memory: "4GB"
        cpu: cores
        preemptible: 1
        docker: "quay.io/biocontainers/goleft:0.2.4--0"
        disks: "local-disk ~{runtime_size} SSD"
        bootDiskSizeGb: runtime_size
    }
    command <<<
        goleft indexcov --extranormalize -d indexcov_out --fai ~{ref_fa_fai} ~{full_wgs_idx}
        tar -cvf indexcov.tar indexcov_out/
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
        File full_wgs
        File full_wgs_idx
        File dnmt3a_mosdepth
    }
    Int cores = 1
    Float bam_size = size([full_wgs], "GB")
    Int runtime_size = 4 + round(bam_size)
    runtime {
        memory: "8GB"
        cpu: cores
        preemptible: 1
        docker: "quay.io/biocontainers/mosdepth:0.2.5--hb763d49_0"
        disks: "local-disk ~{runtime_size} SSD"
        bootDiskSizeGb: runtime_size
    }
    command <<<
        ln -s ~{full_wgs} full.cram
        ln -s ~{full_wgs_idx} full.cram.crai
        ln -s ~{ref_fa} ref.fa
        ln -s ~{ref_fa_fai} ref.fa.fai
        mkdir mosdepth
        mosdepth -b ~{dnmt3a_mosdepth} -n -f ref.fa mosdepth/cnv full.cram
        tar -cvf mosdepth.tar mosdepth/
        gzip mosdepth.tar
    >>>
    output {
        File mosdepth_out = "mosdepth.tar.gz"
    }
}

# Workflow to call samtools_fusions and fusions
workflow runfusions {
    input {
        File wf_fusions_bed
        File wf_full_wgs
        File wf_full_wgs_idx
        File wf_fusions_py
        File wf_ROIs
        File wf_dnmt3a_bed
        File wf_dnmt3a_mosdepth
        File wf_gene_ref_bed
        File wf_ref_fa
        File wf_ref_fa_fai
        File wf_ref_dict
        File Mutect2_intervals
        Int Mutect2_scatter_count
        String Mutect2_gatk_docker
        File Mutect2_gatk_override
        File wf_dnmt3a_mosdepth
    }
    call indexcov {
        input:
        full_wgs_idx=wf_full_wgs_idx,
        ref_fa_fai=wf_ref_fa_fai
    }
    call mosdepth {
        input:
        ref_fa=wf_ref_fa,
        ref_fa_fai=wf_ref_fa_fai,
        full_wgs=wf_full_wgs,
        full_wgs_idx=wf_full_wgs_idx,
        dnmt3a_mosdepth=wf_dnmt3a_mosdepth
    }
    call samtools_fusions {
        input:
        fusions_bed=wf_fusions_bed,
        full_wgs=wf_full_wgs,
        full_wgs_idx=wf_full_wgs_idx,
        ref_fa=wf_ref_fa,
        ref_fa_fai=wf_ref_fa_fai
    }
    call fusions {
        input:
        fusions_py=wf_fusions_py,
        fusions_bam=samtools_fusions.fusions_bam,
        ROIs=wf_ROIs,
        gene_ref_bed=wf_gene_ref_bed
    }
    call samtools_mutect {
        input:
        dnmt3a_bed=wf_dnmt3a_bed,
        full_wgs=wf_full_wgs,
        full_wgs_idx=wf_full_wgs_idx,
        ref_fa=wf_ref_fa,
        ref_fa_fai=wf_ref_fa_fai
    }
    call m2.Mutect2{
        input:
        intervals=Mutect2_intervals,
        ref_fasta=wf_ref_fa,
        ref_fai=wf_ref_fa_fai,
        ref_dict=wf_ref_dict,
        tumor_reads=samtools_mutect.dnmt3a_bam,
        tumor_reads_index=samtools_mutect.dnmt3a_bai,
        scatter_count=Mutect2_scatter_count,
        gatk_docker=Mutect2_gatk_docker,
        gatk_override=Mutect2_gatk_override
    }
    output {
        File fusions_bam = samtools_fusions.fusions_bam
        File fusions_out = fusions.fusions_out
        File dnmt3a_bam = samtools_mutect.dnmt3a_bam
        File dnmt3a_bai = samtools_mutect.dnmt3a_bai
        File filtered_vcf = Mutect2.filtered_vcf
        File filtered_vcf_idx = Mutect2.filtered_vcf_idx
        File filtering_stats = Mutect2.filtering_stats
        File mutect_stats = Mutect2.mutect_stats
        File? contamination_table = Mutect2.contamination_table
        File? funcotated_file = Mutect2.funcotated_file
        File? funcotated_file_index = Mutect2.funcotated_file_index
        File? bamout = Mutect2.bamout
        File? bamout_index = Mutect2.bamout_index
        File? maf_segments = Mutect2.maf_segments
        File? read_orientation_model_params = Mutect2.read_orientation_model_params
        File indexcov_out = indexcov.indexcov_out
        File mosdepth_out = mosdepth.mosdepth_out
    }
}

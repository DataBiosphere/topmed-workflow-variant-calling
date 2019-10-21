#! /bin/bash

# This is a script to run the U of Michigan TopMed variant caller for
# freeze 8 non WDL or CWL wrapped original code as outlined in the README.md
# at https://github.com/statgen/topmed_variant_calling


# Set the exit code of a pipeline to that of the rightmost command
# to exit with a non-zero status, or zero if all commands of the pipeline exit
set -o pipefail
# cause a bash script to exit immediately when a command fails
set -e
# cause the bash shell to treat unset variables as an error and exit immediately
set -u
# echo each line of the script to stdout so we can see what is happening
set -o xtrace
#to turn off echo do 'set +o xtrace'

batchSize=2
sed -i "s/head -n 20/head -n ${batchSize}/g" scripts/run-batch-genotype-local.cmd
sed -i "s/head -n 20/head -n ${batchSize}/g" scripts/run-merge-sites-local.cmd


cd examples/
../apigenome/bin/cloudify --cmd ../scripts/run-discovery-local.cmd
make -f log/discover/example-discovery.mk -k -j 4

mkdir -p out/index
../apigenome/bin/cram-vb-xy-index --index index/list.107.local.crams.index --dir out/sm/ --out out/index/list.107.local.crams.vb_xy.index

mkdir -p out/index
../apigenome/bin/cloudify --cmd ../scripts/run-merge-sites-local.cmd
make -f log/merge/example-merge.mk -k -j 4
../apigenome/bin/cloudify --cmd ../scripts/run-union-sites-local.cmd 4
make -f log/merge/example-union.mk -k -j  4

../apigenome/bin/cloudify --cmd ../scripts/run-batch-genotype-local.cmd
make -f log/batch-geno/example-batch-genotype.mk -k -j 4


../apigenome/bin/cloudify --cmd ../scripts/run-paste-genotype-local.cmd
make -f log/paste-geno/example-paste-genotype.mk -k -j 4

cut -f 1,4,5 index/intervals/b38.intervals.X.10Mb.1Mb.txt | grep -v ^chrX | awk '{print "out/genotypes/hgdp/"$1"/merged."$1"_"$2"_"$3".gtonly.minDP0.hgdp.bcf"}' > out/index/hgdp.auto.bcflist.txt

../bcftools/bcftools concat -n -f out/index/hgdp.auto.bcflist.txt -Ob -o out/genotypes/hgdp/merged.autosomes.gtonly.minDP0.hgdp.bcf
plink-1.9 --bcf out/genotypes/hgdp/merged.autosomes.gtonly.minDP0.hgdp.bcf --make-bed --out out/genotypes/hgdp/merged.autosomes.gtonly.minDP0.hgdp.plink --allow-extra-chr
../king/king -b out/genotypes/hgdp/merged.autosomes.gtonly.minDP0.hgdp.plink.bed --degree 4 --kinship --prefix out/genotypes/hgdp/merged.autosomes.gtonly.minDP0.hgdp.king
../apigenome/bin/vcf-infer-ped --kin0 out/genotypes/hgdp/merged.autosomes.gtonly.minDP0.hgdp.king.kin0 --sex out/genotypes/merged/chr1/merged.chr1_1_1000000.sex_map.txt --out out/genotypes/hgdp/merged.autosomes.gtonly.minDP0.hgdp.king.inferred.ped
../apigenome/bin/cloudify --cmd ../scripts/run-milk-local.cmd
make -f log/milk/example-milk.mk -k -j 4

cut -f 1,4,5 index/intervals/b38.intervals.X.10Mb.1Mb.txt | awk '{print "out/milk/"$1"/milk."$1"_"$2"_"$3".sites.vcf.gz"}' > out/index/milk.autoX.bcflist.txt

(seq 1 22; echo X;) | xargs -I {} -P 10 bash -c "grep chr{}_ out/index/milk.autoX.bcflist.txt | ../bcftools/bcftools concat -f /dev/stdin -Oz -o out/milk/milk.chr{}.sites.vcf.gz"
(seq 1 22; echo X;) | xargs -I {} -P 10 ../htslib/tabix -f -pvcf out/milk/milk.chr{}.sites.vcf.gz
mkdir out/svm
../apigenome/bin/vcf-svm-milk-filter --in-vcf out/milk/milk.chr2.sites.vcf.gz --out out/svm/milk_svm.chr2 --ref resources/ref/hs38DH.fa --dbsnp resources/ref/dbsnp_142.b38.vcf.gz --posvcf resources/ref/hapmap_3.3.b38.sites.vcf.gz --posvcf resources/ref/1000G_omni2.5.b38.sites.PASS.vcf.gz --train --centromere resources/ref/hg38.centromere.bed.gz --bgzip ../htslib/bgzip --tabix ../htslib/tabix --invNorm ../invNorm/bin/invNorm --svm-train ../libsvm/svm-train --svm-predict ../libsvm/svm-predict
(seq 1 22; echo X;) | grep -v -w 2 | xargs -I {} -P 10 ../apigenome/bin/vcf-svm-milk-filter --in-vcf out/milk/milk.chr{}.sites.vcf.gz --out out/svm/milk_svm.chr{} --ref resources/ref/hs38DH.fa --dbsnp resources/ref/dbsnp_142.b38.vcf.gz --posvcf resources/ref/hapmap_3.3.b38.sites.vcf.gz --posvcf resources/ref/1000G_omni2.5.b38.sites.PASS.vcf.gz --model out/svm/milk_svm.chr2.svm.model --centromere resources/ref/hg38.centromere.bed.gz --bgzip ../htslib/bgzip --tabix ../htslib/tabix --invNorm ../invNorm/bin/invNorm --svm-train ../libsvm/svm-train --svm-predict ../libsvm/svm-predict

tar -zvcf topmed_variant_caller_output_file.tar.gz out/svm out/milk

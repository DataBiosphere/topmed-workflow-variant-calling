version 1.0

import "https://raw.githubusercontent.com/DataBiosphere/topmed-workflow-variant-calling/1.0.3/variant-caller-wdl/topmed_freeze8_caller.wdl" as TopMed_variantcaller


workflow checkerWorkflow {
  input {
    File inputTruthVCFFile

    String? docker_image
    String docker_concordance_image = "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.3.2-1510681135"

    Array[File]? input_crai_files
    Array[File] input_cram_files

    File referenceFilesBlob
  }

   call TopMed_variantcaller.TopMedVariantCaller as variantcaller {
     input:
       input_crai_files = input_crai_files,
       input_cram_files = input_cram_files,
       docker_image = docker_image,
       referenceFilesBlob = referenceFilesBlob
   }

  call checkerTask {
      input:
          inputTruthVCFFile = inputTruthVCFFile,
          inputTestVCFFile = variantcaller.topmed_variant_caller_output,
          docker_concordance_image = docker_concordance_image,
          genomeReferenceFileNameAndPath = "resources/ref/hs38DH.fa",
          referenceFileBlob = referenceFilesBlob,
          reference_disk_size = 20.0
  }

  meta {
      author : "Walt Shands"
      email : "jshands@ucsc.edu"
      description: "This is the checker workflow WDL for U of Michigan's [TOPMed Freeze 8 Variant Calling Pipeline](https://github.com/statgen/topmed_variant_calling)"
   }

}


task checkerTask {
  input {
      File inputTruthVCFFile
      File inputTestVCFFile

      File referenceFileBlob
      Float reference_disk_size

      String genomeReferenceFileNameAndPath
      String docker_concordance_image

      Int additional_disk = 20
  }

  Float disk_size = reference_disk_size + size(inputTruthVCFFile, "GB") + size(inputTestVCFFile, "GB") + additional_disk

  command <<<
    python3 <<CODE
    from __future__ import print_function, division
    import sys, os, tarfile, gzip, csv, math, shutil, tarfile
    from subprocess import Popen, PIPE, STDOUT

    print("referenceFileBlob {}".format("~{referenceFileBlob}"))

    print("inputTruthVCFFile file {}".format("~{inputTruthVCFFile}"))
    print("inputTestVCFFile file {}".format("~{inputTestVCFFile}"))

    # Extract the reference files to the resources directory
    print("genomeReferenceFileNameAndPath {}".format("~{genomeReferenceFileNameAndPath}"))

    def read_and_compare_vcfs_from_tar_gz(tar_gz_truth, tar_gz_test, reference_blob, reference):
        """
        Reads the VCF files from the tar gz file produced by the U of Michigan
        WDL variant caller and the truth targ gz file and compares each of them
        and returns 1 if any do not compare favorably and 0 if all of them do.

        """
        print("reference {}".format(reference))

        print("tar_gz_truth {}".format(tar_gz_truth))
        print("tar_gz_test {}".format(tar_gz_test))

        # Extract the reference files to the resources directory
        print("Extracting reference files from {}".format(reference_blob))
        tar = tarfile.open(reference_blob)
        tar.extractall()
        tar.close()


        print("test file:{}    truth file:{}".format(tar_gz_test, tar_gz_truth))
        with tarfile.open(tar_gz_test, "r") as test_variant_caller_output, \
             tarfile.open(tar_gz_truth, "r") as truth_variant_caller_output:

             test_vcf_file_names = test_variant_caller_output.getnames()
             #print("vcf file names are:{}".format(test_vcf_file_names))
             test_vcf_file_basenames = [os.path.basename(file_name) for file_name in test_vcf_file_names]
             #print("vcf file basenames are:{}".format(test_vcf_file_basenames))

             # Check that the truth VCF tar file is not empty; if it is something is wrong
             truth_vcf_file_names = truth_variant_caller_output.getnames()
             if not truth_vcf_file_names or len(truth_vcf_file_names) == 0:
                 print("The truth tar gz file is empty", file=sys.stderr)
                 sys.exit(1)


             for truth_vcf_file_info in truth_variant_caller_output.getmembers():
                 truth_vcf_file_name = os.path.basename(truth_vcf_file_info.name)
                 #print("Truth vcf file name is:{}".format(truth_vcf_file_name))

                 if truth_vcf_file_info.isfile() and \
                    os.path.basename(truth_vcf_file_info.name).endswith("vcf.gz"):

                    #print("Checking to see if truth vcf file {} is present in {}".format(os.path.basename(truth_vcf_file_info.name), tar_gz_test))
                    # If a VCF file is missing in the test output then
                    # the VCFs are not the same and return error
                    if os.path.basename(truth_vcf_file_info.name) not in test_vcf_file_basenames:
                        print("VCF file {} is missing from variant caller output".format(os.path.basename(truth_vcf_file_info.name)), file=sys.stderr)
                        sys.exit(1)

                    # Get file like objects for the gzipped vcf files
                    for test_vcf_file_info in test_variant_caller_output.getmembers():
                       if os.path.basename(test_vcf_file_info.name) == os.path.basename(truth_vcf_file_info.name):
                           test_vcf_file = test_variant_caller_output.extractfile(test_vcf_file_info)
                           #print("Got test vcf file:{} with file name {}".format(test_vcf_file, test_vcf_file_info.name))
                           break;

                    truth_vcf_file = truth_variant_caller_output.extractfile(truth_vcf_file_info)

                    # The following code writes the file-like objects to the host disk.
                    # This is necessary for the Java executable to read the files.
                    fnames = ['truth.vcf', 'test.vcf']
                    file_like_objects = [truth_vcf_file, test_vcf_file]
                    cnt = 0
                    for fl_obj in file_like_objects:
                        with gzip.open(fl_obj, 'r') as f_in, open(fnames[cnt], 'wb') as f_out:
                                shutil.copyfileobj(f_in, f_out)
                        cnt = cnt + 1

                    # Run the GATK VCF checker procedure with those input files.
                    run_concordance(reference, 'truth.vcf', 'test.vcf')

    def run_concordance(reference, truth_file, eval_file):
        """Open a terminal shell to run a command in a Docker
        image with Genotype Concordance installed.
         :return: none
        """

        # Create file to capture GATK Concordance on local host.
        output_file = 'concordance_outputTSV.tsv'

        cmd = ['/usr/gitc/gatk4/gatk-launch',
               'Concordance',
               '-R', str(reference),
               '--eval', eval_file,
               '--truth', truth_file,
               '--summary', str(output_file)]

        p = Popen(cmd, stdout=PIPE, stderr=STDOUT)

        # Show the output from inside the Docker on the host terminal.
        print("GenotypeConcordance out: {}".format(p.communicate()))

        d = process_output_tsv(output_tsv=output_file)
        print(d)  # print to stdout so we read it in WDL

        os.remove(outfile)

    def process_output_tsv(output_tsv, threshold=None):
        """
        Process TSV file written to the current directory.
        :parameter: output_tsv: (string) path to a TSV file from Concordance VCF
        :parameter: threshold: (float) 0 < thresh < 1, sensitivity and precision
                    default: 0.95
        :return: boolean, True is output passes threshold, otherwise false.
        """

        # Set default
        if threshold is None:
            threshold = 0.95
        L = []  # list to capture results

        try:
            with open(output_tsv, newline='') as csvfile:
                file_reader = csv.reader(csvfile, delimiter=' ', quotechar='|')
                for row in file_reader:
                    L.append(row[0])
        except FileNotFoundError:
            print('no output TSV file found')

        if len(L) == 0:
            msg = 'GATK Concordance VCF checker output is empty; no variants - aborting.'
            print(msg)
            sys.exit(1)


        D = list2dict(L)

        # Convert relevant values in dict to floats.
        vals = [D['type']['SNP']['precision'],
                D['type']['SNP']['sensitivity'],
                D['type']['INDEL']['precision'],
                D['type']['INDEL']['sensitivity']]

        if not vals:
            msg = 'GATK Concordance VCF checker output is empty - aborting.'
            print(msg)
            sys.exit(1)

        vals = [float(val) for val in vals]

        # The next line is needed as we encountered NaNs in the output
        # after I run Concordance with two identical inputs for truth and test.
        # It removes NaNs from list.
        vals = [x for x in vals if not math.isnan(x)]

        # Test whether all values pass the threshold test:
        if all(val >= threshold for val in vals):
            message = 'The VCFs can be considered identical.'
            print(message)
            sys.exit(0)
        else:
            message = 'The VCFs do not have enough overlap.'
            print(message)
            sys.exit(1)


    def list2dict(L):
        """Returns a dictionary from input list, originating from the
        Concordance TSV file."""

        dd = {i: L[i].split('\t') for i in range(len(L))}  # auxiliary dict
        D = {}
        # Construct output dictionary of key-value pairs:
        D[dd[0][0]] = {dd[1][0]: dict(zip(dd[0][1:], dd[1][1:])),
                       dd[2][0]: dict(zip(dd[0][1:], dd[2][1:]))}
        return D



    read_and_compare_vcfs_from_tar_gz("~{inputTruthVCFFile}", \
    "~{inputTestVCFFile}", "~{referenceFileBlob}", "~{genomeReferenceFileNameAndPath}")

    CODE
  >>>


  runtime {
    docker: docker_concordance_image
    cpu: "16"
    disks: "local-disk " + ceil(disk_size) + " HDD"
  }
}

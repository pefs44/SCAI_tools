#!/bin/bash
################################################################################
# MRI Image Reconstruction Script from Raw DICOMs
#
# This script copies, unzips, sorts, and optionally converts raw MRI DICOM data
# into BIDS format.
#
# Usage:
#   ./run_reconstruction.sh <filepath> <project_name> [bids]
#
# Arguments:
#   <filepath>       Full path to the zipped MRI file (e.g., sub-BRS0034_20241217.zip)
#   <project_name>   Name of the project
#   [bids]           Optional flag; include "bids" to run BIDS conversion with dcm2bids
#
# Example:
#   ./run_reconstruction.sh /data/storage/sourcedata/BrainResilience/mri/sub-BRS0034_20241217.zip BrainResilience bids
#
# Key Functions:
# - Copies the zip file to /data/storage/test-project/<project_name>/mri/zipped
# - Unzips the contents into /unzipped/sub-<subject>_<date>
# - Sorts the DICOM files into /raw_sorted/sub-<subject>/ses-<date> using dicomsort
# - Optionally converts the sorted data into BIDS using dcm2bids and a config file
#   located at /data/storage/software/config_files/<project_name>_config.json
#
# Requirements:
# - `dicomsort`, `dcm2niix`, and `dcm2bids` must be installed and available in the environment
# - A valid BIDS config JSON file must exist for the project at /data/storage/software/config_files/<project_name>_config.json
#
# Notes:
# - The output directory is hardcoded to /data/storage/projects/
# - This script assumes the zipped file is named using the pattern: sub-<ID>_<YYYYMMDD>.zip
#
# Author: Sunayani Sarkar
#
############################################################################################

# Load dcm2niix software:
# module load dcm2niix
# module load dcm2bids

# get file path from user:
if [ $# -lt 2 ]; then
    echo "Usage: $0 <filepath> <project_name> [bids]"
    exit 1
fi

filepath="$1"
PROJECT_NAME="$2"
RUN_BIDS=0
if [ "$3" == "bids" ]; then
    RUN_BIDS=1
fi

echo "File path provided: $filepath"

# Get directory portion of path
dirpath=$(dirname "$filepath")
old_filename=$(basename "$filepath")
filename=${old_filename#sub-}
filename="${filename#sub_}"
echo "$filename"

# Check if directory exists
if [ ! -d "$dirpath" ]; then
    echo "Error: Directory does not exist: $dirpath"
    exit 1
fi

cd "$dirpath" || {
    echo "Error: Failed to cd to $dirpath"
    exit 1
}

destpath="/data/storage/projects/${PROJECT_NAME}/mri" # CHANGE IF NEEDED

# Check if directory exists. If not, make new directory
# First ensure base destination path exists
[ -d "$destpath" ] || mkdir -p "$destpath" || {
    echo "Error: Could not create destination path $destpath" >&2
    exit 1
}
declare -a dicomsort_raw_dirname=()

# Get subject name (raw_name) without extension
raw_name=${filename%.zip}
dicomsort_raw_dirname+=("$raw_name")


for subject in "${dicomsort_raw_dirname[@]}"; do
    subj_id_short=$(echo "$filename" | sed -E 's/^(sub[-_]?)?([A-Za-z]+)[-_]?([0-9]+).*$/\2\3/i')
    date_yyyymmdd=$(echo "$subject" | grep -oP '[0-9]{8}')
    raw_sorted_dir="$destpath/raw_sorted/sub-$subj_id_short/ses-$date_yyyymmdd"
    raw_sortedz_dir="$destpath/raw_sortedz/sub-$subj_id_short/ses-$date_yyyymmdd"
    
    if [ -d "$raw_sorted_dir" ]; then
        echo "DICOM already sorted at: $raw_sorted_dir"
        echo "Skipping sorting for subject: $subject"
    else

        echo "Processing subject: $subject"
        echo "Creating necessary directories..."

    # Create required directories only if needed
        for dir in zipped unzipped raw_sorted raw_sortedz; do
            [ -d "$destpath/$dir" ] || mkdir -p "$destpath/$dir"
        done

        # Copy zipped file
        if cp "$old_filename" "$destpath/zipped/"; then
            echo "Copied $old_filename to $destpath/zipped/"

            # Check if filenames differ before renaming
            if [[ "$old_filename" != "$filename" ]]; then
                mv "$destpath/zipped/$old_filename" "$destpath/zipped/$filename"
                echo "Renamed to $filename"
            fi
        else
            echo "Error: Copy failed!" >&2
            exit 1
        fi

        # Peek inside ZIP to get top-level folder
        top_level_dir=$(unzip -l "$destpath/zipped/$filename" | awk '{print $4}' | grep '/$' | head -n1 | cut -d/ -f1)
        if [[ "${top_level_dir,,}" != *"${subj_id_short,,}"* || "${top_level_dir,,}" != *"$date_yyyymmdd"* ]]; then
            echo "ERROR: Unzipped folder name mismatch!"
            echo "  Expected folder to include: $subj_id_short and $date_yyyymmdd"
            echo "  Found instead: $top_level_dir"
            exit 1
        fi

        # Unzip if not already unzipped
        output_dir="$destpath/unzipped/sub-$raw_name"
        if [ -d "$output_dir" ]; then
            echo "Unzipped folder exists: $output_dir"
        else
            echo "Unzipping $filename to $destpath/unzipped/"
            unzip -q -o "$destpath/zipped/$filename" -d "$destpath/unzipped/" || {
                echo "Error: Failed to unzip $filename" >&2
                exit 1
            }

            # Find the actual top-level folder created by unzip for this subject
            unzipped_dir=$(find "$destpath/unzipped" -mindepth 1 -maxdepth 1 -type d -iname "*${subj_id_short}*" | head -n1)

            # Standardize folder name
            new_dir="$destpath/unzipped/sub-${subj_id_short}_${date_yyyymmdd}"
            if [ "$unzipped_dir" != "$new_dir" ]; then
                echo "Renaming $unzipped_dir -> $new_dir"
                mv "$unzipped_dir" "$new_dir"
                output_dir="$new_dir"
            fi

            unzipped_dir="$new_dir"
            echo "Unzipped folder: $unzipped_dir"
        fi

        # Cleanup unwanted files before sorting 
        echo "Cleaning unwanted files in $unzipped_dir"

        find "$unzipped_dir" -type f \( \
            -iname "XX_*" -o \
            -iname "PS_*" -o \
            -iname "README.TXT" -o \
            -iname "*.exe" \
        \) -print -delete

        echo "Cleanup done."

        # Run dicomsort
        echo "Running dicomsort on: $subject"
        echo "Sorting DICOMs to: $raw_sorted_dir"
        dicomsort "$output_dir/DICOM" "$raw_sorted_dir/%SeriesDescription-%SeriesNumber/%SOPInstanceUID-%SeriesNumber-%InstanceNumber.dcm" || {
#        dicomsort "$output_dir/DICOM" "$raw_sorted_dir/%SeriesNumber_%SeriesDescription-%SOPInstanceUID.dcm" || {
            echo "Error: dicomsort failed for $subject" >&2
            exit 1
        }
    fi
    
    if [ $RUN_BIDS -eq 1 ]; then
        # Clean ID for BIDS compliance (letters/numbers only, no special chars)
        clean_subject_id=$(echo "$subject" | sed 's/[^a-zA-Z0-9]//g')
        [ -z "$clean_subject_id" ] && clean_subject_id="sub${RANDOM}"

        reconstruction_path="/data/storage/projects/${PROJECT_NAME}/mri/reconstructed" # TO DO: CHANGE TEST-PROJECT

        # Check if directory exists. If not, make new directory
        # First ensure base destination path exists
        [ -d "$reconstruction_path" ] || mkdir -p "$reconstruction_path" || {
            echo "Error: Could not create reconstruction path $reconstruction_path" >&2
            exit 1
        }
        CONFIG_FILE="/data/storage/software/config_files/${PROJECT_NAME}_config.json"
        # Check if config file exists
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "Error: Config file not found at $CONFIG_FILE"
            exit 1
        fi

        echo "Using config file: $CONFIG_FILE"
        participants_tsv="$reconstruction_path/participants.tsv"
        # Reconstruct MRI images with dcm2niix/dcm2bids software:
        bids_subject_dir="${reconstruction_path}/sub-${subj_id_short}/ses-${date_yyyymmdd}"

        if [ -d "$bids_subject_dir" ]; then
            echo "BIDS folder already exists for $subj_id_short ses-$date_yyyymmdd, skipping conversion..."
        else
            dcm2bids \
                -d "$raw_sorted_dir" \
                -p "$subj_id_short" \
                -c "$CONFIG_FILE" \
                -o "$reconstruction_path" \
                -s "$date_yyyymmdd" || {
                    echo "BIDS conversion failed for $subject" >&2
                    continue
                }
        fi

        # Create participants.tsv with header if it doesn't exist
        if [ ! -f "$participants_tsv" ]; then
            echo -e "participant_id\tsession_id\tsex\tweight\tage" > "$participants_tsv"
        fi

        # Call python script to update participants.tsv with demographics
        python3 /data/storage/software/extract_subject_info.py \
            --dicom_path "$raw_sorted_dir" \
            --subject_id "sub-${subj_id_short}" \
            --session_id "ses-${date_yyyymmdd}" \
            --participants_tsv "$participants_tsv"

    #    bids-validator "$reconstruction_path" --ignoreWarnings || true
    else
        echo "Skipping BIDS reconstruction. Only sorting performed."
    fi
    
    # compress the raw-sorted data at the series level
    exedir=$(pwd)
    mkdir -p "${raw_sortedz_dir}"
    cd "${raw_sortedz_dir}"
    for series in "${raw_sorted_dir}"/* ; do
        locseries=$(basename $series)
        if [ -d "${series}" ] ; then
            cp -r "${series}" "${locseries}" 
            echo "Compressing: ${series}"
            zip -r -q "${locseries}.zip" "${locseries}" 
            rm  -r "${locseries}" 
        else
            echo "Error: Raw series folder not found ${series}" >&2
            exit 1
        fi
        if [ -f "${locseries}.zip" ] ; then 
            rm -r "${series}"
            cp "${locseries}.zip" "${series}.zip"
            rm  "${locseries}.zip"
        else 
            echo "Error: zip file not found ${raw_sortedz_dir}/${locseries}.zip" >&2
            exit 1
        fi
    done
    cd "${exedir}"
    rm -r "$destpath/raw_sortedz"
    
done
# ------------------------ Wrap-up ------------------------
if [ $RUN_BIDS -eq 1 ]; then
    echo "BIDS conversion complete."
fi

echo "Processing complete."

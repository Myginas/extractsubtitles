#!/bin/sh
#mkvextract tracks "mkv file name"  "track ID -1":"subtitle file name"

#I want you to act as a software developer. I will provide some specific information script requirements, and it will be your job to come up with an architecture and code for developing for linux shell script. Shell is for very limited and is for embeded systems. Shell script should extract subtitles from mkv video to separate files. Subtitle file names should match video file name. If in video file is more than one subtitle then prompt to select subtitles (in prompt can select multiple subtitles). For job use only ffprobe and ffmpeg. With ffprobe use json format. Save it in variable and filter with jq. Do not use temp files.

# Check if input file is provided and exists
if [ $# -ne 1 ]; then
    echo "Usage: $0 <video_file.mkv>"
    exit 1
fi
if [ ! -f "$1" ]; then
    echo "Error: File '$1' not found"
    exit 1
fi

# Get the directory and base name of the video file (without extension)
dir=$(dirname "$1")
basename=$(basename "$1" .mkv)

# 1. Gather stream information using ffprobe in JSON format
subtitles_info=$(ffprobe -v error -print_format json -show_entries stream=index,codec_type:stream_tags=language,title "$1" 2>/dev/null)

# 2. Filter subtitle streams using jq
# Check if subtitles_info is valid JSON and contains streams
if [ -z "$subtitles_info" ] || echo "$subtitles_info" | jq -e '.streams' >/dev/null 2>&1; then
    subtitles_data=$(echo "$subtitles_info" | jq -r '.streams | to_entries | map(select(.value.codec_type == "subtitle") | {index: .value.index, language: (.value.tags.language // "unknown"), title: (.value.tags.title // "unknown")})')
else
    echo "Error: No valid stream data found in '$1'"
    exit 1
fi

# 3. Check if there are any subtitle streams
if [ $(echo "$subtitles_data" | jq -e 'length > 0') = "true" ]; then
    # 4. Display available subtitles
    echo "Available subtitles:"
    echo "$subtitles_data" | jq -r '["ID","LANGUAGE","TITLE"], ["--","--------","------"], (.[] | [.index, .language, .title]) | @tsv' | awk -F '\t' '{printf "%-4s %-10s %s\n", $1, $2, $3}'
    
    # 5. Prompt user to select subtitle streams (comma-separated for multiple)
    echo "Enter subtitle IDs to extract (e.g., 2 or 2,3 for multiple, or 'all' for all):"
    read -r selection
    
    # 6. Process selection
    if [ "$selection" = "all" ]; then
        selected_ids=$(echo "$subtitles_data" | jq -r '.[].index' | tr '\n' ',' | sed 's/,$//')
    else
        selected_ids=$(echo "$selection" | tr -d ' ' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
    
    # 7. Validate selection
    if [ -z "$selected_ids" ]; then
        echo "Error: No valid selection made"
        exit 1
    fi
    
    # 8. Extract each selected subtitle stream
    for id in $(echo "$selected_ids" | tr ',' ' '); do
        # Get language and title for the current stream
        stream_info=$(echo "$subtitles_data" | jq -r ".[] | select(.index == $id) | .language + \":\" + .title")
        lang=$(echo "$stream_info" | cut -d':' -f1)
        title=$(echo "$stream_info" | cut -d':' -f2)
        
        # Construct output filename with directory
        output_file="${dir}/${basename}.${lang:-unknown}.${id}.srt"
        
        # Extract subtitle using ffmpeg
        echo "Extracting subtitle stream $id (Language: $lang, Title: $title) to $output_file..."
        ffmpeg -v error -i "$1" -map 0:$id -c:s srt -f srt - 2>/dev/null > "$output_file"
        
        if [ $? -eq 0 ]; then
            echo "Successfully extracted to $output_file"
        else
            echo "Error: Failed to extract subtitle stream $id"
        fi
    done
else
    echo "No subtitle streams found in '$1'"
    exit 0
fi
#!/bin/sh
#################################################################################
# Description:	This script remove unnecessary audio and subtitles from media	#
#				files. Converts not supported audio codecs. Renames files.		#
# Date: [2025-05-28]															#
# Version: [1.2]																#
#################################################################################

# Enable debugging mode.
# Loop through all command-line arguments to check for "-d" or "--debug"
for script_argument in "$@"; do
	if [ "$script_argument" = "-d" ] || [ "$script_argument" = "--debug" ]; then
		DEBUG=true
		shift	# Remove the processed argument from the list of arguments.
	fi
done

# Enable debugging.
if [ -n "$DEBUG" ]; then
	if command -v shellcheck > /dev/null 2>&1; then
		shellcheck "$0"
	fi
	set -x
fi

# Record script start time.
script_start_time=$(date +%s)

# Define constants. Change them to best suite you.
DEFAULT_SOURCE="/mnt/Duomenys/Matyti Filmai/arpo testai/" # Default source for movie or TV series. Can be file or directory. Used when not set source.
DEFAULT_MOVIE_DESTINATION="/mnt/Duomenys/Matyti Filmai/" # Default destination for movie. Can be directory. Used when not set destination.
DEFAULT_TV_SHOWS_DESTINATION="/mnt/Duomenys/Matyti Filmai/Serijalai/" # Default TV series directory. Used when not set destination.
LANGUAGES="lit eng rus"	# Preferred and fallback languages. Script chooses languages from left to right.
CONVERT_AUDIO_CODEC="libvorbis" # Audio codec to convert unsupported codecs.
EXTENSIONS=".mkv .avi .mka .mp4 .m2ts .ts" # Script supported file extensions.
SUPPORTED_VIDEO_CODECS="h264 hevc av1 vp9 vp8" # Convert audio with these video codecs.
SUPPORTED_AUDIO_CODECS="vorbis aac mp3 opus flac" # Do not convert audio with these audio codecs.

# Define Global variables.
# Please do not change them.
total_size_difference=0 # Global variable to keep track of total file size difference.
errors="" # Global variable to keep track files with conversation errors.
messages_without_mistakes="" # Global variable to keep track files without conversation errors.
size_difference=0 # Difference in bytes between source and destination files.
ffmpeg_run_time=0 # Time to complete FFmpeg command.
terminal_columns=80 # Terminal text width.
processed_files_count=0 # Count processed files
audio_track_user_choice="" # User chosen audio tracks list.
OVERWRITE_FLAG="" # Overwrite files.
CHECK_FLAG="" # Check files for errors.
NO_VIDEO_FLAG="" # Output only audio and subtitles.
TEST_FLAG="" # Dry run conversation.
AUDIO_FLAG="" # Select only preferred audio tracks.
SKIP_FLAG="" # Do not convert files if no changes will be made to file exept renaming and copying to destination.

# Function to store error and output to screen.
error() {
	errors="$errors$1\n"
	printf "\033[01;31mError: $1\033[0m\n"
}

# Function to ensure last character of string.
confirm_last_character() {
	last_character=$(printf "%s" "$1" | tail -c 1)
	if [ "$last_character" != "$2" ]; then
		echo "$1$2"
	else 
		echo "$1"
	fi
}

# Function to convert bytes to human readable form.
human_readable_size(){
	SIZE="$1" # input size in bytes
	UNITS="B KiB MiB GiB TiB PiB" # list of unit prefixes.

	# Iterate through the units, starting from the smallest and working our way up.
	for UNIT in $UNITS; do
		test "${SIZE%.*}" -lt 1024 && break;

		# Divide the size by 1024 to get a new value for the next unit.
		SIZE=$(awk "BEGIN {printf \"%.2f\",${SIZE}/1024}")
	done

	# if the unit is still "B" at this point, it means we've already converted the size to bytes. 
	# In that case, just print the size with a single space before the unit.
	if [ "$UNIT" = "B" ]; then
		printf "%4.0f %s\n" "$SIZE" "$UNIT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
	else
		printf "%7.02f %s\n" "$SIZE" "$UNIT "| sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
	fi
}

# Main function to rename file, remove video, audio, subtitles and convert unsupported audio tracks.
convert_file(){
	source="$1"

	destination="$2"
	destination_directory="$2"

	# Extract the parent directory of the source path.
	source_subfolder="${source%/*}"
	source_subfolder="${source_subfolder##*/}"
	source_directory=$(dirname "$source")"/"

	# Make destination file name from destination path and source file name.
	extension=$(echo "$source" | awk -F. '{print $NF}')
	source_file_name=$(basename "$source")
	source_file_name="${source_file_name%.*}" # File name without extension.

	destination_subfolder="${destination_directory%/*}"
	destination_subfolder="${destination_subfolder##*/}"

	# Clean symbols in source_file_name.
	renamed_file_name=$source_file_name
	renamed_file_name=$(echo "$renamed_file_name" | sed 's/\.\./tas_hkas/g') # Replace .. to tas_hkas
	renamed_file_name=$(echo "$renamed_file_name" | sed 's/\./ /g')	# Replace all . to space.
	renamed_file_name=$(echo "$renamed_file_name" | sed 's/tas_hkas/./g') # Replace tas_hkas to .
	renamed_file_name=$(echo "$renamed_file_name" | sed 's/_/ /g')	# Replace all _ to space.
	renamed_file_name=$(echo "$renamed_file_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//') # Remove both leading and trailing spaces.
	renamed_file_name=$(echo "$renamed_file_name" | sed 's/ \+/ /g' ) # Substitute multiple spaces with a single space.
	renamed_file_name=$(echo "$renamed_file_name" | sed 's#\(.*\) /#\1/#') # Replace last " /" to "/" for TV series directory creation.

	pattern="([Ss])([0-9]+)[._ -]?([Ee])([0-9]+)"
	# Regular expression to match various TV series patterns
	series_pattern=$(echo "$renamed_file_name" | grep -Eo "$pattern")

	if [ -n "$series_pattern" ]; then
		normalized_series=""
		for pattern in $series_pattern;do
			# If TV series pattern found, normalize it to the "S01E01" format.
			season=$(echo "$pattern" | sed -E 's/[^0-9]*([0-9]+)[^0-9]+([0-9]+)/\1/')
			episode=$(echo "$pattern" | sed -E 's/[^0-9]*([0-9]+)[^0-9]+([0-9]+)/\2/')
			# Remove leading zeros from season and episode variables.
			season=$(echo "$season" | sed 's/^0*//')
			episode=$(echo "$episode" | sed 's/^0*//')
			normalized_series="$(printf "$normalized_series")S$(printf "%02d" "$season")E$(printf "%02d" "$episode")"
		done

		# Add subfolder for TV series only if not set destination.
		if [ "$destination_directory" = "$DEFAULT_TV_SHOWS_DESTINATION" ]; then
			# ${renamed_file_name%%$series_pattern*} - TV series name before S01E01, if start with S01E01 then = "".
			TV_show_name=$(echo "${renamed_file_name%%$series_pattern*}" | sed 's/[^[:alnum:]_]*$//')
			if [ -n "$TV_show_name" ];then
				destination_subfolder="$TV_show_name"
			else
				destination_subfolder="$source_subfolder"
			fi
			destination_directory="$destination_directory$destination_subfolder/"
		fi

		# Check if $renamed_file_name starts with the series pattern.
		if echo "$renamed_file_name" | grep -q "^$series_pattern"; then
			# Replace series patern to normalized series of renamed file
			destination=$(echo "$renamed_file_name" | sed "s/$series_pattern/$normalized_series/g")
		else
			# Trim everything after TV series pattern.
			destination=$(echo "$renamed_file_name" | sed "s/$series_pattern.*//")
			destination="$destination$normalized_series"
		fi

	else
		# If no TV series pattern found, keep the original string and search movie pattern.
		# If destination starts with DEFAULT_TV_SHOWS_DESTINATION change it to DEFAULT_MOVIE_DESTINATION.
		if echo "$destination_directory" | grep -q "^$DEFAULT_TV_SHOWS_DESTINATION"; then
			destination_directory=$(echo "$destination_directory" | sed "s|$DEFAULT_TV_SHOWS_DESTINATION|$DEFAULT_MOVIE_DESTINATION|g")
		fi

		current_year=$(date +%Y)
		valid_year=""
		# Extract all four-digit numbers from the renamed_file_name and filter out the between 1902 and current_year.
		for year in $(echo "$renamed_file_name" | grep -oE '[0-9]{4}'); do
			# First movie was released 1902.
			if [ "$year" -ge 1902 ] && [ "$year" -le "$current_year" ]; then
				valid_year=$year
			fi
		done

		 # Check if the variable 'valid_year' is not empty.
		if [ -n "$valid_year" ]; then
			# Truncate the file name after the last occurrence of the year.
			# If the filename contains the year surrounded by double parentheses (e.g., "file((2023))").
			if echo "$renamed_file_name" | grep -q "(($valid_year))"; then
				destination="${renamed_file_name%%(*}"
			# If the filename contains the year surrounded by parentheses (e.g., "file(2023)").
			elif echo "$renamed_file_name" | grep -q "($valid_year)"; then
				destination="${renamed_file_name%%"($valid_year)"*}"
			else # If the filename contains the year without surrounding parentheses (e.g., "file2023").
				destination="${renamed_file_name%"$valid_year"*}"
			fi
			
			# Check if the last character is " " in destination. If not, add " ".
			destination=$(confirm_last_character "$destination" " ")
			# Output in "destination (2023)" format.
			destination="$destination($valid_year)"
		else
			# If do not found years then fallback to source file name.
			destination="$source_file_name"
		fi

		destination_subfolder="${destination_directory%/*}"
		destination_subfolder="${destination_subfolder##*/}"

		# Movie nfo file path.
		if [ -f "${source%.*}.nfo" ]; then
			nfo_flag=true
		elif [ -f "$source_directory""movie.nfo" ]; then
			nfo_flag=true
		else
			nfo_flag=""
		fi

#TODO: rename destination_subfolder to destination_sub_folder
		# Rename parent folder if it same as file name.
		if [ -n "$nfo_flag" ];then 
			# if destination_sub_folder != source file name and destination_sub_folder != destination then add sub folder.
			if [ "$destination_subfolder" != "$source_file_name" ]; then
				if [ "$destination_subfolder" != "$destination" ]; then
					destination_directory="$destination_directory$destination/"
				fi
			# if destination_subfolder = source_file_name then replace destiantion_subfolder with destination.
			else
				destination_directory=$(echo "$destination_directory" | sed "s/$source_subfolder/$destination/")
			fi
		fi
	fi

	# Rename destination_subfolder if it is same as source file name.
	destination_subfolder="${destination_directory%/*}"
	destination_subfolder="${destination_subfolder##*/}"
	if [ "$source_file_name" = "$destination_subfolder" ]; then
		destination_directory=$(echo "$destination_directory" | sed "s/$destination_subfolder/$destination/")
		destination_subfolder="$destination"
	fi

	# Audio file save as .mka in source directory.
	if [ -n "$NO_VIDEO_FLAG" ]; then
		if echo "$destination_directory" | grep -q "^$DEFAULT_TV_SHOWS_DESTINATION"; then 
			destination="${source%.*}.mka"
		elif echo "$destination_directory" | grep -q "^$DEFAULT_MOVIE_DESTINATION"; then
			destination="${source%.*}.mka"
		else 
			destination="$destination_directory$destination.mka" #(no_video).$extension"
		fi

	else
		# Destination path + normalized file name + source extension.
		destination="$destination_directory$destination.$extension"
	fi

	echo "Source file: $source"
	# FFprobe command to extract video, audio and subtitles information.
		 if ! file_streams="$(ffprobe -v error -print_format json -show_entries stream=index,codec_type,codec_name:stream_tags=language,title "$source")";then
			error "Extracting stream information from (${1#"$source_directory"})."
			return 1
		fi

	file_streams=$(echo "$file_streams" | jq -r '[.streams[]|{index: .index, codec_name: .codec_name, codec_type: .codec_type, language: .tags.language, title: .tags.title}]')
	if [ -n "$file_streams" ]; then
		json_query_command='(["ID:","CODEC:","TYPE:","LANGUAGE:","TITLE:"]), (.[] | [.index, .codec_name, .codec_type, .language, .title]) | @tsv'
		echo "$file_streams" | jq -r "$json_query_command" | awk -F '\t' '{printf "%-3s %-17s %-9s %-9s %-0s\n", $1, $2, $3, $4, $5}'
	fi

	# Select audio tracks based on preferred and fallback languages.
	selected_audio_tracks=""
	audio_language=""
	for language in $LANGUAGES; do
		audio_tracks="$(echo "$file_streams" | jq -r --arg lang "$language" '.[] | select(.codec_type == "audio" and .language == $lang) | .index')"
		if [ -n "$audio_tracks" ]; then
			selected_audio_tracks="$audio_tracks"
			audio_language=$language
			break
		fi
	done
	# Select default audio track language if no selected_audio_tracks.
	if [ -z "$selected_audio_tracks" ]; then 
		# Select all audio tracks if not found preferred languages.
		selected_audio_tracks="$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "audio") | .index')"
	fi

	# Count selected audio track before adding commentary audio track.
	selected_audio_tracks_count=$(echo "$selected_audio_tracks" | grep -c "")

	# Add commentary audio.
	commentary_audio="$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "audio" and .title != null) | select(.title | contains("Commentary"))')"

	if [ -n "$commentary_audio" ]; then
		# Select commentary subtitles by languages.
		for language in $LANGUAGES; do 
			if [ "$language" != "$audio_language" ];then
				commentary_audio_track=$(echo "$commentary_audio" | jq -r --arg lang "$language" '. | select(.language == $lang) | .index')
				if [ -n "$commentary_audio_track" ]; then
					if [ -n "$selected_audio_tracks" ];then
						selected_audio_tracks="$selected_audio_tracks $commentary_audio_track"
					else 
						selected_audio_tracks="$commentary_audio_track"
					fi
					break
				fi
			fi
		done
	fi

	# If more than one selected audio track then ask user select tracks to keep.
	if [ "$selected_audio_tracks_count" -gt 1 ]; then
		# Check if -a parameter is given to script.
		if [ -z "$audio_track_user_choice" ]; then
			# Construct the jq command dynamically
			json_query_command=""
			for selected_audio_track in $selected_audio_tracks; do
			# Append audio index element to jq command.
				if [ -z "$json_query_command" ]; then
					json_query_command="$selected_audio_track"
				else 
					json_query_command="$json_query_command,$selected_audio_track"
				fi
			done

			echo
			echo "Found $selected_audio_tracks_count audio tracks of $audio_language language"
			json_query_command='(["ID:","LANGUAGE:","TITLE:"]), (.['"$json_query_command"'] | [.index, .language, .title]) | @tsv'
			echo "$file_streams" | jq -r "$json_query_command" | awk -F '\t' '{printf "%-3s %-9s %-0s\n", $1, $2, $3}'
			
			# Read user input
			read -p "Select the audio tracks Id's you want to keep, multiple Id's can be separated by spaces: " audio_track_user_choice
			#tr -d '[:punct:]'` to remove any punctuation from the input, ensuring that it doesn't contain special characters.
			audio_track_user_choice=$(echo "$audio_track_user_choice" | tr -d '[:punct:]')
		fi

		# Split the user input in words and check each one.
		user_selected_audio_tracks=""
		for user_audio_track in $audio_track_user_choice; do
			if echo "$user_audio_track" | grep -q '^[0-9]'; then
				for selected_audio_track in $selected_audio_tracks; do
					if [ "$user_audio_track" -eq "$selected_audio_track" ]; then
						if [ -z "$user_selected_audio_tracks" ];then
							user_selected_audio_tracks="$user_audio_track"
						else
							user_selected_audio_tracks="$user_selected_audio_tracks $user_audio_track"
						fi
						break
					fi
				done
			fi
		done

		# Change selected audio track to user selected audio tracks.
		if [ -n "$user_selected_audio_tracks" ]; then
			selected_audio_tracks="$user_selected_audio_tracks"
		fi

		# Reset audio track choice if not set as script argument.
		if [ -z "$AUDIO_FLAG" ]; then
			audio_track_user_choice=""
		fi
	fi

	# Run ffprobe to get information about the video streams.
	video_codecs=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "video") | .codec_name')

	# Check if any video codec is supported.
	video_codec_supported=""
	for video_codec in $video_codecs; do
		# Check if the codec is in the SUPPORTED_VIDEO_CODECS array.
		for supported_video_codec in $SUPPORTED_VIDEO_CODECS; do
			if [ "$supported_video_codec" = "$video_codec" ]; then
				video_codec_supported=true
				break
			fi
		done
	done

	# Select subtitles.
	subtitle_language=""
	for language in $LANGUAGES; do
		subtitle_tracks=$(echo "$file_streams" | jq -r --arg lang "$language" '.[] | select(.codec_type == "subtitle" and .language == $lang) | .index')
		if [ -n "$subtitle_tracks" ]; then
			subtitle_language="$language"
			break
		fi

		# Do not include fall back languages.
		if [ "$audio_language" = "$language" ]; then
			break
		fi
	done

	# Select commentary subtitles.
	commentary_subtitle=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "subtitle" and .title != null) | select(.title | contains("Commentary"))')
	if [ -n "$commentary_subtitle" ]; then
		# Select commentary subtitles by languages.
		for language in $LANGUAGES; do
			if [ "$language" != "$subtitle_language" ];then
				commentary_subtitle_tracks=$(echo "$commentary_subtitle" | jq -r --arg lang "$language" '. | select(.language == $lang) | .index')
				if [ -n "$commentary_subtitle_tracks" ]; then
					if [ -n "$subtitle_tracks" ]; then
						subtitle_tracks="$subtitle_tracks $commentary_subtitle_tracks"
					else 
						subtitle_tracks="$commentary_subtitle_tracks"
					fi
					break
				fi
			fi
		done
	fi

	# If not found preferred audio or subtitles languages then take all subtitles.
	if [ -z "$audio_language" ]; then
		if [ -z "$subtitle_language" ]; then
			subtitle_tracks=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "subtitle") | .index')
		fi
	fi

	# Build the FFmpeg command.
	# -xerror -fflags +fastseek -max_muxing_queue_size 999 -bitexact
	ffmpeg_command="ffmpeg -xerror -err_detect explode -flags -global_header -hide_banner -i \"$source\""

	# Do not output video.
	if [ -n "$NO_VIDEO_FLAG" ]; then
		ffmpeg_command="$ffmpeg_command -vn"
		selected_destination_tracks=""
		# Add video and remove title.
	elif [ -n "$video_codecs" ]; then
		ffmpeg_command="$ffmpeg_command -map 0:V:0 -metadata title=\"\" -c:V:0 copy -metadata:s:v title=\"\""
		selected_video_tracks="$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "video" and .codec_name != "mjpeg" and .codec_name != "jpeg" and .codec_name != "png") | .index')"
	fi

	# Map audio tracks.
	for audio_track in $selected_audio_tracks; do
		ffmpeg_command="$ffmpeg_command -map 0:$audio_track"
	done

	# Add audio tracks.
	audio_track_index=0
	# Count how much audio and subtitles tracks will be copied without conversation.
	not_changed_tracks=0
	for audio_track in $selected_audio_tracks; do
		audio_codec="$(echo "$file_streams" | jq -r --arg audio_track "$audio_track" '.[$audio_track|tonumber].codec_name')"

		# Check if a audio codec is supported.
		audio_codec_supported=""
		for supported_codec in $SUPPORTED_AUDIO_CODECS; do
			if [ "$audio_codec" = "$supported_codec" ]; then
				audio_codec_supported=true
				break
			fi
		done

		# Decide convert or copy audio track.
		if [ -n "$video_codec_supported" ] || [ -z "$video_codecs" ] || [ -n "$NO_VIDEO_FLAG" ]; then
			if [ -n "$audio_codec_supported" ]; then
				ffmpeg_command="$ffmpeg_command -c:a:$audio_track_index copy"
				not_changed_tracks=$(( not_changed_tracks + 1 ))
			else
				ffmpeg_command="$ffmpeg_command -c:a:$audio_track_index $CONVERT_AUDIO_CODEC"
				# Change codec name for destination screen output.
				file_streams=$(echo "$file_streams" | jq --arg index "$audio_track" --arg codec_name "$CONVERT_AUDIO_CODEC" '.[] |= if .index == ($index | tonumber) then .codec_name = $codec_name else . end')
			fi
		else
			ffmpeg_command="$ffmpeg_command -c:a:$audio_track_index copy"
			not_changed_tracks=$(( not_changed_tracks + 1 ))
		fi
		audio_track_index=$(( audio_track_index + 1 ))
	done

	# Add subtitles to FFmpeg command.
	if [ -n "$subtitle_tracks" ]; then
		for subtitle_track in $subtitle_tracks; do
			ffmpeg_command="$ffmpeg_command -map 0:$subtitle_track"
			not_changed_tracks=$(( not_changed_tracks + 1 ))
		done
		# Do not convert subtitles.
		ffmpeg_command="$ffmpeg_command -c:s copy"
	fi

	# Count source audio and subtitles tracks.
	audio_and_subtitle_count=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "audio" or .codec_type == "subtitle") | .index' | grep -c "")

	# Check need of conversation audio or strip some tracks.
	if [ "$not_changed_tracks" -eq "$audio_and_subtitle_count" ]; then
		#	Convert files even no changes will be made to file exept renaming and copying to destination.
		if [ -z "$SKIP_FLAG" ] || [ -n "$NO_VIDEO_FLAG" ]; then
			# Copy the file with ffmpeg.
			ffmpeg_command="ffmpeg -xerror -err_detect explode -flags -global_header -hide_banner -i \"$source\""
			if [ -n "$NO_VIDEO_FLAG" ]; then
				# Copy without video tracks.
				ffmpeg_command="$ffmpeg_command -vn -c copy"
			else
				# Copy with video tracks.
				ffmpeg_command="$ffmpeg_command -c copy -metadata:s:v title=\"\""
			fi
		else
			error "Skipping (${1#"$source_directory"}) because do not need to convert this file."
			return 1
		fi
	fi

	# Do not prompt to overwrite existing files.
	if [ -n "$OVERWRITE_FLAG" ]; then
		ffmpeg_command="$ffmpeg_command -y"
	# Do not overwrite existing files when skipping files.
	elif [ -n "$SKIP_FLAG" ]; then
		ffmpeg_command="$ffmpeg_command -n"
	fi

	# Finish of creating ffmpeg command.
	ffmpeg_command="$ffmpeg_command \"$destination\""

	# Create not existing destination directory.
	directory=$(dirname "$destination")
	if [ ! -d "$directory" ] && [ -z "$TEST_FLAG" ]; then
		create_directory_command="mkdir -p \"$directory\""
		# Create directory and check for errors.
		if ! eval "$create_directory_command";then
			error "FFmpeg cannot create file in not existing directory. Skipping (${source#"$source_directory"}) file."
			return 1
		fi
	fi

	# Output destination file information.
	# Construct the destination jq command.
	selected_destination_tracks="$selected_video_tracks $selected_audio_tracks $subtitle_tracks"
	json_query_command=""
	for id in $selected_destination_tracks; do
	# Append selected indexes to jq command.
		if [ -z "$json_query_command" ]; then
			json_query_command="$id"
		else 
			json_query_command="$json_query_command,$id"
		fi
	done

	json_query_command='[ "ID:", "CODEC:", "TYPE:", "LANGUAGE:", "TITLE:"], (.['"$json_query_command] | {index: .index, codec_name: .codec_name, codec_type: .codec_type, language: .language, title: .title} | [.index, .codec_name, .codec_type, .language, .title]) | @tsv"
	echo
	echo "Destination file: $destination"
	echo "$file_streams" | eval "jq -r '$json_query_command'" | awk -F '\t' '{printf "%-3s %-17s %-9s %-9s %-0s\n", $1, $2, $3, $4, $5}'

	echo
	echo "$ffmpeg_command"

	# Check if source and destination are the same.
	if [ "$source" -ef "$destination" ] && [ -z "$TEST_FLAG" ]; then
		error "Source and destination cannot be the same file (${source#"$source_directory"})."
		return 1
	fi

	# Record the FFmpeg start time.
	ffmpeg_start_time=$(date +%s)

	if [ -z "$TEST_FLAG" ]; then
		# Run FFmpeg command and check FFmpeg errors.
		if ! eval "$ffmpeg_command";then
			# Record the FFmpeg end time.
			ffmpeg_end_time=$(date +%s)
			ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
			error "$ffmpeg_command"
			return 1
		fi

		if [ -z "$NO_VIDEO_FLAG" ]; then
			# Import xml elements from destination nfo file to source nfo file.
			# TV show nfo file path.
			if [ -f "$source_directory""tvshow.nfo" ]; then
				nfo_flag=true
			fi

			if [ -n "$nfo_flag" ]; then
				for source_nfo_file in .nfo movie.nfo tvshow.nfo;do
					
					# Create source and destination nfo file path.
					if [ "$source_nfo_file" = ".nfo" ]; then 
						destination_nfo_file="${destination%.*}$source_nfo_file"
						source_nfo_file="${source%.*}$source_nfo_file"
					else
						destination_nfo_file="$destination_directory$source_nfo_file"
						source_nfo_file="$source_directory$source_nfo_file"
					fi

					# Chek if exist source nfo file.
					if [ -f "$source_nfo_file" ]; then 
						# Delete empty xml <element></element> elements from source_nfo_file file.
						sed -i '/^\s*<[^>]*>\s*<\/[^>]*>\s*$/d' "$source_nfo_file"
						# Delete empty xml <element/> elements from source_nfo_file file.
						sed -i '/^\s*<[^>]*\/>\s*$/d' "$source_nfo_file"
						
						if [ -f "$destination_nfo_file" ]; then
							# Get XML elements tabulator.
							xml_tabulator=$(grep -o '^ *' "$source_nfo_file" | head -n 1)

							for xml_element in "userrating" "watched" "playcount" "dateadded" "lastplayed"; do
								# Extract the value from the destination_nfo_file XML file.
								destination_xml_value=$(grep "<$xml_element>" "$destination_nfo_file" | sed -e "s/.*<$xml_element>\([^<]*\)<\/$xml_element>.*/\1/")
								# Check if a valid value was extracted.
								if [ -n "$destination_xml_value" ]; then
									source_xml_value=$(grep "<$xml_element>" "$source_nfo_file" | sed -e "s/.*<$xml_element>\([^<]*\)<\/$xml_element>.*/\1/")
									if [ -n "$source_xml_value" ]; then
										# Update the source file only if the destination value is different from the source value.
										if [ "$destination_xml_value" != "$source_xml_value" ]; then
											sed -i "s/<$xml_element>[^<]*<\/$xml_element>/<$xml_element>$destination_xml_value<\/$xml_element>/" "$source_nfo_file"
											echo "$xml_tabulator<$xml_element> updated from $source_xml_value to $destination_xml_value"
										fi
									else
										# Insert the element into the appropriate parent tag in the souce file (movie, tvshow, epsodedetail).
										for xml_root_element in "movie" "episodedetails" "tvshow"; do
											if ! grep -q "<$xml_root_element>" "$source_nfo_file"; then
												continue
											fi

											# Insert line before closing xml root element "</movie>, </episodedetails> or </tvshow>".
											if [ -n "$xml_root_element" ];then 
												sed -i "/<\/$xml_root_element>/ i\\$xml_tabulator<$xml_element>$destination_xml_value</$xml_element>" "$source_nfo_file"
												echo "$xml_tabulator<$xml_element> value $destination_xml_value inserted into <$xml_root_element>"
											fi
											break
										done
									fi
								fi
							done
						fi
					fi
				done

				# move all kodi files that names begin same as file name.
				kodi_files=$(find "$source_directory" -maxdepth 1 -type f -name "$source_file_name*" -not -name "$source_file_name.$extension")

				if [ -n "$kodi_files" ]; then
					
					#IFS` determines which characters separate the fields in each line of data.
					SAVE_IFS=$IFS
					IFS="$(printf '\n\t')" #Change Internal Field Separator to newline or tab. Why do not work with only '\n'?

					for kodi_file in $kodi_files; do
						# Extract the relative path and construct destination path
						kodi_file_destination="${kodi_file#"${source%.*}"}"
						kodi_file_destination="${destination%.*}$kodi_file_destination"
							move_file_command="mv -f \"$kodi_file\" \"$kodi_file_destination\""
							echo "$move_file_command"
							if ! eval "$move_file_command";then
								# Record move kodi files error
								error "moving \"$kodi_file\" file."
							fi
					done
					IFS=$SAVE_IFS
				fi

				# move kodi files that does not start same as file name.
				for pattern in tvshow.nfo poster.* movie.* folder.* cover.* fanart* backdrop* banner.* clearart.* disc.* discart.* thumb.* landscape.* clearlogo.* logo.* keyart.* characterart.* season* tvshow-trailers.* trailer.*; do
					kodi_files=$(find "${source%/*}" -maxdepth 1 -type f -name "$pattern")
					if [ -n "$kodi_files" ];then

						#IFS` determines which characters separate the fields in each line of data.
						SAVE_IFS=$IFS
						IFS="$(printf '\n\t')" #Change Internal Field Separator to newline or tab. Why do not work with only '\n'?

						for kodi_file in $kodi_files; do
							kodi_file_destination="$destination_directory"$(basename "$kodi_file")
							move_file_command="mv -f \"$kodi_file\" \"$kodi_file_destination\""
							echo "$move_file_command"
							if ! eval "$move_file_command";then
								error "moving \"$kodi_file\" file."
							fi
						done
						IFS=$SAVE_IFS
					fi
				done

				# move kodi folders.
				for folder in .actors/ trailers/ extrafanart/; do
					if [ -d "$source_directory$folder" ]; then
						move_file_command="rsync -av --remove-source-files \"$source_directory$folder\" \"$destination_directory$folder\""
						echo "$move_file_command"
						if ! eval "$move_file_command";then
							error "moving \"$source_directory$folder\" folder."
						else 
							rmdir "$source_directory$folder"
						fi
					fi
				done
			fi
		fi
	else
		# Register all successful fmmpeg commands.
		messages_without_mistakes="$messages_without_mistakes$ffmpeg_command\n"
		# ffmpeg command execution time with error or dry run.
		ffmpeg_end_time=$(date +%s)
		ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
		return 1
	fi

	# Successful FFmpeg end time.
	ffmpeg_end_time=$(date +%s)

	# Calculate the difference in seconds.
	ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
	# Format the execution time using date command.
	formatted_time=$(date -u -d @"$ffmpeg_run_time" +"%T")
	# Output time in format hours:minutes:seconds how long took function and how long took whole script to finish.

	# Compare source and destination files after conversation.
	destination_size=0
	source_size=$(stat "$source" | grep "Size:" | awk '{print $2}')
	if [ -f "$destination" ]; then
		destination_size=$(stat "$destination" | grep "Size:" | awk '{print $2}')
	fi

	# Check if the destination file is bigger than the source file.
	if [ "$destination_size" -gt "$source_size" ]; then
		error "Destination file (${destination#"$input_destination"}) is bigger than source file (${source#"$source_directory"})."
		return 1
	fi

	# Check if the destination file is less than 10% of the source file size.
	ten_percent=$((source_size / 10))
	if [ "$destination_size" -lt "$ten_percent" ] || [ "$destination_size" -eq 0 ] && [ -z "$NO_VIDEO_FLAG" ]; then
		error "Destination file (${destination#"$input_destination"}) is less than 10% of the source file. Deleting it."

		# Delete destination file.
		if [ -f "$destination" ]; then
			rm "$destination"
		fi
		return 1
	fi

	# Make destination file modification date same as source.
	if [ -f "$destination" ]; then
		touch -r "$source" "$destination"
	else 
		error "Destination file (${destination#"$input_destination"}) does not exist."
		return 1
	fi

	# Calculate the difference in sizes.
	size_difference=$((source_size - destination_size))

	# Output saved disk size of every file.
	if [ "$size_difference" -gt 0 ]; then
		saved_size="Saved: $(human_readable_size $size_difference) and it took $formatted_time to do so."
		printf "\033[01;32m$saved_size\033[00m\n"
	else
		error "${destination#"$input_destination"} is same size as source"
		return	1
	fi

	# Register all successful FFmpeg commands.
	messages_without_mistakes="$messages_without_mistakes$ffmpeg_command\n$saved_size\n"

	# Update the total saved bytes.
	total_size_difference=$((total_size_difference + size_difference))
}

# Function to check a file for errors.
check_file(){
	echo "Source file is: $1"

	# Record the FFmpeg start time.
	ffmpeg_start_time=$(date +%s)

	#eval ffmpeg -err_detect explode -v error -hide_banner -i \"$1\" -c copy -f null - 2>&1 >/dev/null
	# Run ffmpeg and capture its output and exit status
	#without video
	#ffmpeg_output=$(ffmpeg -v error -i "$1" -vn -f null - 2>&1)
	#ffmpeg_output=$(ffmpeg -v error -xerror -err_detect explode -i "$1" -f null - 2>&1)
	#ffmpeg -xerror -err_detect explode -hide_banner -i "$1" -f null -
	#ffmpeg -hwaccels -hide_banner #shows GPU accelerators.
	#ffmpeg -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -xerror -err_detect explode -hide_banner -i "$1" -f null - #works 10x slower
	# ffmpeg_output do not show ffmpeg status, but catch more errors.
	#echo "ffmpeg -benchmark -hwaccel vdpau -xerror -err_detect explode -v error -i \"$1\" -f null - 2>&1"
	#ffmpeg_output=$(ffmpeg -benchmark -hwaccel vdpau -xerror -err_detect explode -v error -i "$1" -f null - 2>&1)

	#Shows ffmpeg status but do not catch all errors.
	ffmpeg_command="ffmpeg -benchmark -hwaccel vdpau -xerror -err_detect explode -hide_banner -i \"$1\" -f null -" #vdpau works faster than cuda
	#ffmpeg_command="ffmpeg -benchmark -hwaccel cuda -xerror -err_detect explode -hide_banner -i \"$1\" -f null -" #cuda
	echo "$ffmpeg_command"

	if [ -z "$TEST_FLAG" ]; then
		#Run FFmpeg command and check FFmpeg errors.
		if ! eval "$ffmpeg_command";then
			# Record the FFmpeg end time.
			ffmpeg_end_time=$(date +%s)
			ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
			formatted_time=$(date -u -d @"$ffmpeg_run_time" +"%T")
			error "$1. Check took $formatted_time"
			return 1
		else
			ffmpeg_end_time=$(date +%s)
			ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
			formatted_time=$(date -u -d @"$ffmpeg_run_time" +"%T")

			printf "\033[01;32mOK: $1. Check took $formatted_time to do so.\033[0m\n"
			messages_without_mistakes="$messages_without_mistakes$1\n"
		fi
	else
		# Dry run. Do nothing.
		messages_without_mistakes="$messages_without_mistakes$1\n"
		ffmpeg_end_time=$(date +%s)
		ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
	fi
}

# Function to process files in a directory recursively.
process_directory() {
	source="$1"

	# Loop through files and sub folders in the folder.
	for path in "$source"*; do
		if [ -d "$path" ]; then
		# Recursively process sub folders.
		process_directory "$path/"

		elif [ -f "$path" ]; then
			# Check if a file has a valid extension.
			file_extension=".${path##*.}"
			for extension in $EXTENSIONS; do
				if [ "$extension" = "$file_extension" ]; then
					
					# Set same sub folder for destination as source.
					directory=$(dirname "$path")
					subfolder="${directory#"$source_directory"}"
					if [ "$directory" = "$subfolder" ]; then
						subfolder=""
					fi

					# Print horizontal file separator line.
					if [ -n "$job_separator" ]; then 
						echo "$job_separator"
					else
						# generate default lenght job separator
						job_separator=$(printf '%*s' "$terminal_columns" " " | tr ' ' '-')
					fi

					# Change job separator lenght by terminal width.
					if command -v "tput" > /dev/null 2>&1; then
						if [ "$(tput cols)" -ne "$terminal_columns" ]; then
							terminal_columns=$(tput cols)
							job_separator=$(printf '%*s' "$terminal_columns" " " | tr ' ' '-')
						fi
					fi

					# Count processed files.
					processed_files_count=$(( processed_files_count + 1 ))
					
					# Determine the operation based on --check parameter.
					if [ -n "$CHECK_FLAG" ]; then
						# Check files
						check_file "$path"
					else
						if [ -n "$subfolder" ];then
							destination="$input_destination$subfolder/"
						else
							destination="$input_destination"
						fi

						# Convert file
						convert_file "$path" "$destination"
					fi
				break # Valid extension found.
				fi
			done
		fi
		subfolder=""
	done
}

# Program beginning:
# Check essential programs for script.
for program in ffprobe ffmpeg; do
	if ! command -v "$program" > /dev/null 2>&1; then
		error "$program is not installed. Please install it first"
		exit 1
	fi
done

# Set default source and destination
source="$DEFAULT_SOURCE"
destination="$DEFAULT_TV_SHOWS_DESTINATION"

while [ $# -gt 0 ]; do
	case "$1" in
		-a|--audio)
			AUDIO_FLAG=true
			shift
			# Collect numeric parameters for the -a flag.
			while [ $# -gt 0 ] && echo "$1" | grep -q '^[0-9]*$'; do
				if [ -z "$audio_track_user_choice" ]; then
					audio_track_user_choice=$1
				else
					audio_track_user_choice="$audio_track_user_choice $1"
				fi
				shift
			done
			;;
		-c|--check)
			CHECK_FLAG=true
			shift
			;;
		-h|--help)
			echo "Usage:"
			echo "$(basename "$0") [-a index [index ...]] [-c] [-d] [-o] [-s] [-t] [-v] [source] [destination]"
			echo "  If no parameters are provided, default source and destination are used."
			echo "  Default source is $DEFAULT_SOURCE"
			echo "  Default destination for movies is $DEFAULT_MOVIE_DESTINATION"
			echo "  Default destination for TV shows is $DEFAULT_TV_SHOWS_DESTINATION"
			echo "  Languages selection priority:"
			for language in $LANGUAGES;do
				language_number=$((language_number + 1))
				printf "\t%s\n" "$language_number. $language"
			done
			echo "  Source can be file or directory."
			echo "  Destination can be only directory."
			echo "  Supported files extensions $EXTENSIONS"
			echo "  If one parameter is provided, it is considered as the source."
			echo "  If two parameters are provided the first is source, second is destination."
			echo "  -a, --audio		Specify audio tracks (space-separated list of FFmpeg indexes)."
			echo "  -c, --check		Checks file for errors."
			echo "  -d, --debug		Enables script debugging."
			echo "  -o, --overwrite	Do not prompt for overwriting existing files."
			echo "  -s, --skip		Skip files that do not need audio/subtitle conversation/removal."
			echo "  -t, --test		Print only FFmepg commands (dry run)."
			echo "  -v, --video		Excludes video. Output only audio and subtitles."
			echo "Example:"
			echo "  $(basename "$0")			# Use default source and destination."
			echo "  $(basename "$0") source		# Use source as specified."
			echo "  $(basename "$0") -c source		# Check specified source for errors."
			echo "  $(basename "$0") -a 1 3 source	# Select 1 and 3 audio tracks"
			echo "  $(basename "$0") -v source		# Do not add video to output file."
			echo "  $(basename "$0") -t source		# Dry run without actual conversation."
			echo "  $(basename "$0") source destination	# Use specified source and destination."
			exit 0
			;;
		-o|--overwrite)
			OVERWRITE_FLAG=true
			shift
			;;
		-s|--skip)
			SKIP_FLAG=true
			shift
			;;
		-t|--test)
			TEST_FLAG=true
			shift
			;;
		-v|--video)
			NO_VIDEO_FLAG=true
			shift
			;;
		*)
			if [ $# -eq 1 ]; then
				# One parameter provided, use it as the source.
				source=$1
			elif [ $# -eq 2 ]; then
				# Two parameters provided, use the first as the source and the second as the destination.
				source="$1"
				destination="$2"
			else
				# More than two parameters provided, treat as error.
				echo "Error in given arguments:"
				for script_argument in "$@"; do
					argument_number=$(( argument_number + 1 ))
					echo "$argument_number. $script_argument"
				done
				echo
				echo "$(basename "$0") --help"
				exec "$0" --help
				exit 1
			fi
			break
	esac
done

# Confirm if the last character of $input_destination is '/'
input_destination=$(confirm_last_character "$destination" "/")

# Check more file extensions than convert.
if [ -n "$CHECK_FLAG" ]; then
#	echo "Run ffmpeg -formats and extract the formats. Please wait..."
#	# Run ffmpeg -formats and extract the formats
#	EXTENSIONS=$(ffmpeg -demuxers -hide_banner | tail -n +5 | cut -d' ' -f4 | xargs -i{} ffmpeg -hide_banner -h demuxer={} | grep 'Common extensions' | cut -d' ' -f7 | tr ',' $'\n' | tr -d '.'))
#	# Because very slow extract formats it is faster use baked variable.
	EXTENSIONS=".mkv .avi .mp4 .mka .aac .ac3 .mov .mp2 .mp3 .ogg .vc1 .dss .dts .eac3 .flac .flv .hevc .m2a .m4a .m4v .mks .3g2 .3gp .aa3"
fi

# Check if user given source exist.
if [ -f "$source" ]; then
	source_directory=$(dirname "$source")"/"
	process_directory "$source"
	return 0 # Exit without messages output
# If source is directory then remember user file paths.
elif [ -d "$source" ]; then
	# Confirm if the last character of $source is '/'
	source=$(confirm_last_character "$source" "/")

	# Directories inputted by user or defaults.
	source_directory="$source"
	process_directory "$source"
else
	echo "Source \"$source\" does not exist or is not a media file. Use media files with these $EXTENSIONS extensions or directory with media files."
	exit 1
fi

# Output messages only if more than 1 file processed.
if [ "$processed_files_count" -gt 1 ]; then

	# Output successful FFmpeg commands.
	if [ -n "$messages_without_mistakes" ]; then
			echo "$job_separator"
			if [ -n "$CHECK_FLAG" ]; then
				echo "Successful checks:"
			elif [ -n "$TEST_FLAG" ]; then
				echo "All FFmpeg commands:"
			else
				echo "Successful conversations:"
			fi
			printf "\033[01;32m$messages_without_mistakes\033[00m"
	fi

	# Output files with errors.
	if [ -n "$errors" ]; then
		echo "$job_separator"
		printf "Files with errors is:\n\033[01;31m$errors\033[00m"
	fi

	# Record the end time.
	script_end_time=$(date +%s)

	# Calculate the difference in seconds.
	script_execution_time=$((script_end_time - script_start_time))

	# Format the execution time using date command.
	script_execution_time=$(date -u -d @"$script_execution_time" +"%T")

	if [ -n "$TEST_FLAG" ]; then
		echo "Dry run for $processed_files_count files took $script_execution_time."
	elif [ -n "$CHECK_FLAG" ]; then
		echo "$processed_files_count files check complete in $script_execution_time"
	elif [ "$total_size_difference" -gt "$size_difference" ]; then
		echo "Total saved: $(human_readable_size $total_size_difference) and it took $script_execution_time to do so."
	fi
fi

CONFIG_PATH=/data/options.json

# Get configuration
SENSOR_STATE_TYPE="$(jq --raw-output '.sensor_state_type' $CONFIG_PATH)"
ADDITIONAL_SENSOR_STATE_TYPES="$(jq --raw-output '.additional_sensor_state_types' $CONFIG_PATH)"
SENSOR_NAME="$(jq --raw-output '.sensor_name' $CONFIG_PATH)"
ADDITIONAL_SENSOR_NAMES="$(jq --raw-output '.additional_sensor_names' $CONFIG_PATH)"
FRIENDLY_NAME="$(jq --raw-output '.friendly_name' $CONFIG_PATH)"
ADDITIONAL_FRIENDLY_NAMES="$(jq --raw-output '.additional_friendly_names' $CONFIG_PATH)"
HDD_PATH="$(jq --raw-output '.hdd_path' $CONFIG_PATH)"
ADDITIONAL_HDD_PATHS="$(jq --raw-output '.additional_hdd_paths' $CONFIG_PATH)"
DEVICE_TYPE="$(jq --raw-output '.device_type' $CONFIG_PATH)"
ADDITIONAL_DEVICE_TYPES="$(jq --raw-output '.additional_device_types' $CONFIG_PATH)"
DEBUG="$(jq --raw-output '.debug' $CONFIG_PATH)"
OUTPUT_FILE="$(jq --raw-output '.output_file' $CONFIG_PATH)"
ATTRIBUTES_PROPERTY="$(jq --raw-output '.attributes_property' $CONFIG_PATH)"
ATTRIBUTES_FORMAT="$(jq --raw-output '.attributes_format' $CONFIG_PATH)"

# Convert the additional values to arrays
IFS=' ' read -r -a ADDITIONAL_SENSOR_STATE_TYPES_ARRAY <<< "$ADDITIONAL_SENSOR_STATE_TYPES"
IFS=' ' read -r -a ADDITIONAL_SENSOR_NAMES_ARRAY <<< "$ADDITIONAL_SENSOR_NAMES"
IFS=' ' read -r -a ADDITIONAL_FRIENDLY_NAMES_ARRAY <<< "$ADDITIONAL_FRIENDLY_NAMES"
IFS=' ' read -r -a ADDITIONAL_HDD_PATHS_ARRAY <<< "$ADDITIONAL_HDD_PATHS"
IFS=' ' read -r -a ADDITIONAL_DEVICE_TYPES_ARRAY <<< "$ADDITIONAL_DEVICE_TYPES"

# Merge the single values and the arrays into new arrays
MERGED_SENSOR_STATE_TYPES=("$SENSOR_STATE_TYPE" "${ADDITIONAL_SENSOR_STATE_TYPES_ARRAY[@]}")
MERGED_SENSOR_NAMES=("$SENSOR_NAME" "${ADDITIONAL_SENSOR_NAMES_ARRAY[@]}")
MERGED_FRIENDLY_NAMES=("$FRIENDLY_NAME" "${ADDITIONAL_FRIENDLY_NAMES_ARRAY[@]}")
MERGED_HDD_PATHS=("$HDD_PATH" "${ADDITIONAL_HDD_PATHS_ARRAY[@]}")
MERGED_DEVICE_TYPES=("$DEVICE_TYPE" "${ADDITIONAL_DEVICE_TYPES_ARRAY[@]}")

if [ "$DEBUG" = "true" ]; then
    # Print the merged arrays
    echo "Merged Sensor State Types: ${MERGED_SENSOR_STATE_TYPES[*]}"
    echo "Merged Sensor Names: ${MERGED_SENSOR_NAMES[*]}"
    echo "Merged Friendly Names: ${MERGED_FRIENDLY_NAMES[*]}"
    echo "Merged HDD Paths: ${MERGED_HDD_PATHS[*]}"
    echo "Merged Device Types: ${MERGED_DEVICE_TYPES[*]}"

fi

for i in "${!MERGED_HDD_PATHS[@]}"; do

    echo "[$(date)][INFO] Processing disk at list index $i with path ${MERGED_HDD_PATHS[$i]}"

    HDD_PATH="${MERGED_HDD_PATHS[$i]}"
    SENSOR_STATE_TYPE="${MERGED_SENSOR_STATE_TYPES[$i]}"
    SENSOR_NAME="${MERGED_SENSOR_NAMES[$i]}"
    FRIENDLY_NAME="${MERGED_FRIENDLY_NAMES[$i]}"
    DEVICE_TYPE="${MERGED_DEVICE_TYPES[$i]}"

    SMARTCTL_OUTPUT=$(/usr/sbin/smartctl -a "$HDD_PATH" -d "$DEVICE_TYPE" --json)

    if [ "$DEBUG" = "true" ]; then
        echo "$SMARTCTL_OUTPUT" > "/share/hdd_tools/${OUTPUT_FILE}_$i"
    fi

    if ! [ -z "$SENSOR_STATE_TYPE" ]; then
        case "$SENSOR_STATE_TYPE" in
            temperature)
                if [[ $SENSOR_NAME != sensor\.* ]]; then
                    echo "[$(date)][ERROR] The sensor name \"$SENSOR_NAME\" must start by 'sensor.' for 'temperature' mode!"
                    exit 1
                fi
                TEMPERATURE_VALUE=$(echo $SMARTCTL_OUTPUT | jq --raw-output '.temperature.current')
                echo "[$(date)][INFO] Sensor value as temperature: ${TEMPERATURE_VALUE}"
                SENSOR_DATA='{"state": "'"$TEMPERATURE_VALUE"'", "attributes": {"unit_of_measurement":"°C","friendly_name":"'"$FRIENDLY_NAME"'","device_class":"temperature","state_class":"measurement"}}'
            ;;
            smart_state)
                if [[ $SENSOR_NAME != binary_sensor\.* ]]; then
                    echo "[$(date)][ERROR] The sensor name \"$SENSOR_NAME\" must start by 'binary_sensor.' for 'smart_state' mode!"
                    exit 1
                fi
                SMART_STATUS_VALUE=$(echo $SMARTCTL_OUTPUT | jq --raw-output '.smart_status.passed')
                PROBLEM_STATUS_VALUE="on"
                if [ "$SMART_STATUS_VALUE" = "true" ]; then
                    PROBLEM_STATUS_VALUE="off"
                fi
                echo "[$(date)][INFO] Sensor value as smart_state: ${SMART_STATUS_VALUE}, problem: ${PROBLEM_STATUS_VALUE}"
                SENSOR_DATA='{"state": "'"$PROBLEM_STATUS_VALUE"'", "attributes": {"friendly_name":"'"$FRIENDLY_NAME"'","device_class":"problem"}}'
            ;;
            *)
                echo "[$(date)][ERROR] Unsupported sensor state type \"$SENSOR_STATE_TYPE\" given!"
                exit 1
            ;;
        esac
    fi

    if [ "$DEBUG" = "true" ]; then
        echo "[$(date)][DEBUG] Sensor data before attributes: $SENSOR_DATA"
    fi

    if ! [ -z "$ATTRIBUTES_PROPERTY" ]; then
        ATTRIBUTES=$(echo $SMARTCTL_OUTPUT | jq -e --raw-output ".${ATTRIBUTES_PROPERTY}" || echo "{}")

        case "$ATTRIBUTES_FORMAT" in
            object)
            ;;
            list)
                ATTRIBUTES=$(echo $ATTRIBUTES | jq 'map({(if .name == "Unknown_Attribute" then "Unknown_Attribute_" + (.id | tostring) else .name end): .raw.string | capture("^(?<value>[[:digit:]]+)").value | tonumber}) | add | with_entries(.key |= ascii_downcase)')
            ;;
            *)
                echo "[$(date)][ERROR] Unsupported attributes format \"$ATTRIBUTES_FORMAT\" given!"
                exit 1;
            ;;
        esac

        SENSOR_DATA=$(echo $SENSOR_DATA | jq ".attributes += $ATTRIBUTES")
    fi

    if [ "$DEBUG" = "true" ]; then
        echo "[$(date)][DEBUG] Sensor data which would be pushed to home-assistant and exposed as \"$SENSOR_NAME\": $SENSOR_DATA"
        echo "[$(date)][DEBUG] debug is enabled, sensor data is not published to home-assistant!"
        exit 0;
    fi

    curl -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
           -s \
           -o /dev/null \
           -H "Content-Type: application/json" \
           -d "$SENSOR_DATA" \
           -w "[$(date)][INFO] Sensor update response code: %{http_code}\n" \
           "http://supervisor/core/api/states/${SENSOR_NAME}"
done
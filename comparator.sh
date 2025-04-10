#!/bin/bash

echo "                                                    _"
echo "                                                   | |"
echo "  ___   ___   _ __ ___   _ __    __ _  _ __   __ _ | |_   ___   _ __"
echo " / __| / _ \ | '_ \` _ \ | '_ \  / _\` || '__| / _\` || __| / _ \ | '__|"
echo "| (__ | (_) || | | | | || |_) || (_| || |   | (_| || |_ | (_) || |"
echo " \___| \___/ |_| |_| |_|| .__/  \__,_||_|    \__,_| \__| \___/ |_|"
echo "                        | |"
echo "                        |_|"

DIFFERENCES=""
MATCHES=""

# Функции для сравнения файлов (первая часть)
compare_process_folder() {
    local folder_path="$1"
    
    echo "____________________________________"
    # Преобразование YAML в JSON
    yaml_files=("$folder_path"/*.yaml)
    json_files=()
    
    for yaml_file in "${yaml_files[@]}"; do
        json_file="${yaml_file%.yaml}.json"
        yq eval -o=json "$yaml_file" > "$json_file"
        json_files+=("$json_file")
        echo "Преобразован $yaml_file в $json_file"
    done
    
    # Сравнение JSON-файлов
    if [ "${#json_files[@]}" -ge 2 ]; then
        compare_json "${json_files[0]}" "${json_files[1]}"
    else
        echo "Недостаточно файлов для сравнения."
    fi
    
    # Создание документов с результатами
    if [ "${#yaml_files[@]}" -ge 2 ]; then
        # Документ расхождений
        if [ -n "$DIFFERENCES" ]; then
            diff_file="${folder_path}/расхождения_$(date +%Y%m%d%H%M%S).yaml"
            echo "Создание документа расхождений в $diff_file..."
            : > "$diff_file"
            while IFS= read -r path; do
                if [ -n "$path" ]; then
                    echo "#Путь: $path" >> "$diff_file"
                    for yaml_file in "${yaml_files[@]}"; do
                        data=$(cat "$yaml_file")
                        echo "#Файл: $(basename "$yaml_file")" >> "$diff_file"
                        get_data_by_path "$data" "$path" >> "$diff_file" 2>/dev/null
                        echo >> "$diff_file"
                    done
                    echo >> "$diff_file"
                fi
            done <<< "$DIFFERENCES"
            echo "Документ расхождений сохранен в $diff_file"
        else
            echo "Нет расхождений для сохранения."
        fi

        # Документ совпадений (в старом формате)
        if [ -n "$MATCHES" ]; then
            match_file="${folder_path}/совпадения_$(date +%Y%m%d%H%M%S).yaml"
            echo "Создание документа совпадений в $match_file..."
            : > "$match_file"
            data=$(cat "${yaml_files[0]}")
            while IFS= read -r path; do
                if [ -n "$path" ]; then
                    echo "#Путь: $path" >> "$match_file"
                    get_data_by_path "$data" "$path" >> "$match_file" 2>/dev/null
                    echo >> "$match_file"
                fi
            done <<< "$MATCHES"
            echo "Документ совпадений (раздельный формат) сохранен в $match_file"
            
            # Создаем объединенный YAML манифест из совпадений
            merged_file="${folder_path}/объединенный_манифест_$(date +%Y%m%d%H%M%S).yaml"
            echo "Создание объединенного YAML манифеста в $merged_file..."
            : > "$merged_file"
            
            # Используем yq для постепенного построения манифеста
            temp_yaml="${folder_path}/temp.yaml"
            : > "$temp_yaml"
            
            # Начинаем с пустого документа
            echo "{}" | yq eval -o yaml > "$temp_yaml"
            
            while IFS= read -r path; do
                if [ -n "$path" ]; then
                    # Получаем значение из первого файла
                    value=$(get_data_by_path "$data" "$path" 2>/dev/null | tail -n +2 | yq eval -o json)
                    
                    # Преобразуем путь в формат yq с экранированием
                    yq_path=$(echo "$path" | 
                              sed -E 's/([^\.\[]+)(\[[0-9]+\])?/."\1"\2/g' |
                              sed 's/\.\././g')
                    
                    # Обновляем временный файл
                    yq eval -i "$yq_path = $value" "$temp_yaml"
                fi
            done <<< "$MATCHES"
            
            # Конвертируем в красивый YAML и сохраняем
            yq eval -P "$temp_yaml" > "$merged_file"
            rm -f "$temp_yaml"
            
            echo "Объединенный YAML манифест сохранен в $merged_file"     
            
            # # Конвертируем JSON обратно в YAML и сохраняем
            # echo "$merged_yaml" | yq eval -P > "$merged_file"
            # echo "Объединенный YAML манифест сохранен в $merged_file"
        else
            echo "Нет совпадений для сохранения."
        fi
    fi

    # Удаление временных JSON файлов
    rm -f "${json_files[@]}"
}

# Остальные функции остаются без изменений
compare_json() {
    local file1=$1
    local file2=$2
    echo "Сравниваем $file1 и $file2"

    # Получаем различия с значениями
    differences=$(jq -rn --slurpfile file1 "$file1" --slurpfile file2 "$file2" '
        def compare_paths($path; $a; $b):
            if $a == $b then
                empty
            else
                "\($path | join(".")): \($a | @json) vs \($b | @json)"
            end;

        def walk($a; $b; $path):
            if ($a | type) == "object" and ($b | type) == "object" then
                (($a | keys) + ($b | keys) | unique) as $keys
                | $keys[] as $key
                | walk($a[$key]; $b[$key]; $path + [$key])
            elif ($a | type) == "array" and ($b | type) == "array" then
                if ($a | length) == ($b | length) then
                    range(0; $a | length) as $i
                    | walk($a[$i]; $b[$i]; $path + [$i])
                else
                    "\($path | join(".")): array length mismatch (\($a | length) vs \($b | length))"
                end
            else
                compare_paths($path; $a; $b)
            end;

        walk($file1[]; $file2[]; [])' | sed -E 's/\.([0-9]+)/[\1]/g' | sed -E 's/:.*$//'| sed 's/\.[^.]*$//' | uniq)

    # Получаем совпадения с значениями
    matches=$(jq -rn --slurpfile file1 "$file1" --slurpfile file2 "$file2" '
        def compare_paths($path; $a; $b):
            if $a == $b then
                "\($path | join(".")): \($a | @json)"
            else
                empty
            end;

        def walk($a; $b; $path):
            if ($a | type) == "object" and ($b | type) == "object" then
                (($a | keys) + ($b | keys) | unique) as $keys
                | $keys[] as $key
                | walk($a[$key]; $b[$key]; $path + [$key])
            elif ($a | type) == "array" and ($b | type) == "array" then
                if ($a | length) == ($b | length) then
                    range(0; $a | length) as $i
                    | walk($a[$i]; $b[$i]; $path + [$i])
                else
                    empty
                end
            else
                compare_paths($path; $a; $b)
            end;

        walk($file1[]; $file2[]; [])' | sed -E 's/\.([0-9]+)/[\1]/g' | sed -E 's/:.*$//'| sed 's/\.[^.]*$//' | uniq)

    DIFFERENCES="$differences"
    MATCHES="$matches"

    # Выводим различия
    echo
    echo "Различия:"
    echo
    echo "$differences"

    # Выводим совпадения
    echo
    echo "Совпадения:"
    echo
    echo "$matches"
}

print_keys() {
    local data="$1"
    local indent="$2"
    local current_level="$3"
    local max_level="$4"

    if [[ -n "$max_level" && "$current_level" -ge "$max_level" ]]; then
        return
    fi

    keys=$(echo "$data" | yq eval 'keys | .[]' -)

    for key in $keys; do
        echo "${indent}${key}"

        value=$(echo "$data" | yq eval ".\"$key\"" -)

        if echo "$value" | yq eval 'tag == "!!map"' - | grep -q "true"; then
            print_keys "$value" "$indent  " "$((current_level + 1))" "$max_level"
        fi

        if echo "$value" | yq eval 'tag == "!!seq"' - | grep -q "true"; then
            echo "$value" | yq eval '.[] | select(tag == "!!map")' - | while read -r item; do
                print_keys "$item" "$indent  " "$((current_level + 1))" "$max_level"
            done
        fi
    done
}

get_data_by_path() {
    local data="$1"
    local path="$2"
    local result

    IFS='.' read -r -a path_components <<< "$path"

    result="$data"
    for component in "${path_components[@]}"; do
        if [[ "$component" =~ ^([^[]+)\[([0-9]+)\]$ ]]; then
            key="${BASH_REMATCH[1]}"
            index="${BASH_REMATCH[2]}"
            result=$(echo "$result" | yq eval ".\"$key\"[$index]" -)
        else
            result=$(echo "$result" | yq eval ".\"$component\"" -)
        fi

        if [[ -z "$result" ]]; then
            echo "Ключ '$path' не найден."
            return 1
        fi
    done

   cleaned_component=$(echo "${path_components[-1]}" | sed -E 's/\[[0-9]+\]//g')
    echo "$cleaned_component:"
    echo "$result" | yq eval -o=json | yq eval -P | sed 's/^/  /'
    return 0
}

save_to_file() {
    local data="$1"
    local default_name="$2"

    read -p "Хотите сохранить результат в файл? (y/n): " save_choice
    if [[ "$save_choice" == "y" || "$save_choice" == "Y" ]]; then
        read -p "Введите имя файла (по умолчанию: $default_name): " file_name
        file_name="${file_name:-$default_name}"

        echo "$data" > "$file_name.yaml"
        echo "Результат сохранен в файл: $file_name"
    else
        echo "Сохранение отменено."
    fi
}

process_folder() {
    local folder_path="$1"

    yaml_files=("$folder_path"/*.yaml)

    echo "____________________________________"
    echo "Список файлов:"
    for i in "${!yaml_files[@]}"; do
        echo "$i: ${yaml_files[$i]}"
    done
    echo

    read -p "Введите уровень вложенности (оставьте пустым для вывода всех ключей): " max_level

    all_keys=""
    for selected_file in "${yaml_files[@]}"; do
        echo "Обрабатывается файл: $selected_file"
        data=$(cat "$selected_file")
        all_keys+="Ключи в файле $selected_file:\n\n"
        all_keys+="$(print_keys "$data" "" 0 "$max_level")\n\n"
    done

    echo "____________________________________"
    echo -e "$all_keys"

    while true; do
        echo "Что вы хотите сделать с ключами?"
        echo "1. Показать только выбранные ключи"
        echo "2. Удалить выбранные ключи и показать оставшийся манифест"
        read -p "Введите номер действия: " action

        if [[ "$action" != "1" && "$action" != "2" ]]; then
            echo "Ошибка: неверный номер действия."
            continue
        fi

        read -p "Введите ключи для работы (через пробел): " selected_keys

        case $action in
            1)
                echo
                for selected_file in "${yaml_files[@]}"; do
                    data=$(cat "$selected_file")
                    echo "____________________________________"
                    echo "$selected_file"
                    echo
                    for key in $selected_keys; do
                        key_data=$(get_data_by_path "$data" "$key")
                        if [[ $? -eq 0 ]]; then
                            echo "$key_data"
                        fi
                    done
                    echo
                done

                save_to_file "$(for selected_file in "${yaml_files[@]}"; do
                    data=$(cat "$selected_file")
                    echo "#Файл: $selected_file"
                    for key in $selected_keys; do
                        key_data=$(get_data_by_path "$data" "$key")
                        if [[ $? -eq 0 ]]; then
                            echo "$key_data"
                        fi
                    done
                    echo
                done)" "selected_keys.yaml"
                ;;
            2)
                for selected_file in "${yaml_files[@]}"; do
                    data=$(cat "$selected_file")
                    filtered_data="$data"
                    for key in $selected_keys; do
                        key_escaped=$(echo "$key" | sed 's/\./\\./g')
                        filtered_data=$(echo "$filtered_data" | yq eval "del(.\"$key_escaped\")" -)
                    done
                    echo "Отфильтрованный манифест для файла $selected_file:"
                    echo "____________________________________"
                    echo "$filtered_data"
                    echo

                    save_to_file "$filtered_data" "filtered_manifest_$(basename "$selected_file")"
                done
                ;;
        esac

        read -p "Хотите продолжить работу с ключами? (y/n): " continue_choice
        if [[ "$continue_choice" != "y" && "$continue_choice" != "Y" ]]; then
            break
        fi
    done
}

if [ "$#" -ne 1 ]; then
    echo "Использование: $0 <путь_к_папке>"
    exit 1
fi

main_menu() {
    while true; do
        echo
        echo "Выберите действие:"
        echo "1. Автоматическое сравнение файлов"
        echo "2. Ручное сравнение файлов"
        echo "3. Выход"
        read -p "Введите номер действия: " action

        case $action in
            1)
                echo "Автоматическое сравнение файлов"
                compare_process_folder "$1"
                ;;
            2)
                echo "Ручное сравнение файлов"
                process_folder "$1"
                ;;
            3)
                echo "Выход"
                exit 0
                ;;
            *)
                echo "Ошибка: неверный номер действия."
                ;;
        esac
    done
}

main_menu "$1"
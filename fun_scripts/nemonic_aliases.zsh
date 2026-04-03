# ==========================================
# NEMONIC PRINTER ALIASES & FUNCTIONS
# ==========================================

function _nemonic_print_pdf_stream() {
    local tmp_pdf
    tmp_pdf="$(mktemp -t nemonic_fun)"
    mv "$tmp_pdf" "${tmp_pdf}.pdf"
    tmp_pdf="${tmp_pdf}.pdf"
    cat > "$tmp_pdf"

    local media_box
    media_box="$(strings -n 1 "$tmp_pdf" | sed -En 's/.*\/MediaBox \[0 0 ([0-9.]+) ([0-9.]+)\].*/\1 \2/p' | head -n 1)"
    if [ -z "$media_box" ]; then
        echo "Failed to determine PDF page size." >&2
        rm -f "$tmp_pdf"
        return 1
    fi

    local pdf_width pdf_height
    read -r pdf_width pdf_height <<< "$media_box"

    # The printer width is fixed at 80mm (226.8pt). Height is variable.
    local page_height
    page_height="$(awk -v h="$pdf_height" 'BEGIN { h = (h < 72.0) ? 72.0 : (h > 708.7 ? 708.7 : h); printf "%.1f", h }')"

    lp -d Nemonic_MIP_201 -o "media=Custom.226.8x${page_height}" "$tmp_pdf"
    local rc=$?
    rm -f "$tmp_pdf"
    return $rc
}

# 1. The Instant To-Do List
function todo() {
    if [ $# -eq 0 ]; then
        echo "Usage: todo 'Task 1' 'Task 2'"
        return 1
    fi
    (
        echo "TO-DO LIST"
        echo "===================="
        for item in "$@"; do
            echo "[ ] $item"
        done
    ) | nemonic_texttopng | _nemonic_print_pdf_stream
    echo "Todo list printed!"
}

# 2. Pomodoro / Single Focus Task
function focus() {
    if [ -z "$1" ]; then
        echo "Usage: focus 'One specific task'"
        return 1
    fi
    (
        echo "CURRENT FOCUS"
        echo "===================="
        echo ""
        echo "[ ] $1"
    ) | nemonic_texttopng | _nemonic_print_pdf_stream
    echo "Focus task printed! Stick it to your monitor."
}

# 3. The Morning Weather Sticky
function weather() {
    local loc="${1:-}"
    echo "Fetching weather..."
    curl -s "wttr.in/${loc}?0Tq" | nemonic_texttopng | _nemonic_print_pdf_stream
    echo "Weather printed!"
}

# 4. Physical GitHub Ticket / Kanban Board
function ticket() {
    if ! command -v gh &> /dev/null; then
        echo "GitHub CLI (gh) not found. Please install it with: brew install gh"
        return 1
    fi
    if [ -z "$1" ]; then
        echo "Usage: ticket <issue-number-or-url>"
        return 1
    fi
    echo "Fetching issue..."
    gh issue view "$1" | sed -r "s/\x1B\[[0-9;]*[mK]//g" | nemonic_texttopng | _nemonic_print_pdf_stream
    echo "Ticket printed!"
}

# 5. ASCII Joke / Fortune Cow
function joke() {
    if ! command -v fortune &> /dev/null || ! command -v cowsay &> /dev/null; then
        echo "Installing fortune and cowsay first..."
        brew install fortune cowsay
    fi
    fortune | cowsay | nemonic_texttopng | _nemonic_print_pdf_stream
    echo "Cow joke printed!"
}

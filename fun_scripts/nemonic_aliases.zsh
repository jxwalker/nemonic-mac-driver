# ==========================================
# NEMONIC PRINTER ALIASES & FUNCTIONS
# ==========================================

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
    ) | nemonic_texttopng | lpr -P Nemonic_MIP_201
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
    ) | nemonic_texttopng | lpr -P Nemonic_MIP_201
    echo "Focus task printed! Stick it to your monitor."
}

# 3. The Morning Weather Sticky
function weather() {
    local loc="${1:-}"
    echo "Fetching weather..."
    curl -s "wttr.in/${loc}?0Tq" | nemonic_texttopng | lpr -P Nemonic_MIP_201
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
    gh issue view "$1" | sed -r "s/\x1B\[[0-9;]*[mK]//g" | nemonic_texttopng | lpr -P Nemonic_MIP_201
    echo "Ticket printed!"
}

# 5. ASCII Joke / Fortune Cow
function joke() {
    if ! command -v fortune &> /dev/null || ! command -v cowsay &> /dev/null; then
        echo "Installing fortune and cowsay first..."
        brew install fortune cowsay
    fi
    fortune | cowsay | nemonic_texttopng | lpr -P Nemonic_MIP_201
    echo "Cow joke printed!"
}

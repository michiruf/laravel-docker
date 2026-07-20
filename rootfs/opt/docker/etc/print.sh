#!/usr/bin/env sh

RESET='\033[0m'

p() {
    case $2 in
        red)    color='\033[0;31m' ;;
        yellow) color='\033[0;33m' ;;
        purple) color='\033[0;35m' ;;
        cyan)   color='\033[0;36m' ;;
        *)      color='' ;;
    esac

    printf '%b\n' "${color}${1}${RESET}"
}

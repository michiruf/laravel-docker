#!/usr/bin/env sh

RESET='\033[0m'

p() {
    text=$1
    case $2 in
        red)    color='\033[0;31m' ;;
        green)  color='\033[0;32m' ;;
        yellow) color='\033[0;33m' ;;
        blue)   color='\033[0;34m' ;;
        purple) color='\033[0;35m' ;;
        cyan)   color='\033[0;36m' ;;
        white)  color='\033[0;37m' ;;
        *)      color='' ;;
    esac

    printf '%b\n' "${color}${text}${RESET}"
}

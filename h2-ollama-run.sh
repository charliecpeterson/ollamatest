#!/bin/bash
## This script will run Rstudio server on Hoffman2
## This uses an Apptainer container with R/Rstudio
# Author Charlie Peterson <cpeterson@oarc.ucla.edu>
# Date Created: 2/2/2022
# Date Modified: 3/9/2022 - change to apptainer

## TO DO:
##
## extra qrsh check
## multiple core check
##

# Function to print the banner
print_banner() {
  local RESET=$'\e[0m'
  local HEADER_BG=$'\e[44;97m'  # White text on blue background
  local BORDER_BG=$'\e[46;97m'  # White text on cyan background
  local TEXT_COLOR=$'\e[93m'    # Yellow text
  local QUIT_MSG=$'\e[31m'      # Red text

  clear  # Clears the terminal to make it clean

  # Top border
  echo -e "${BORDER_BG}══════════════════════════════════════════════════════════════════════════════════════${RESET}"

  # Title
  echo -e "${HEADER_BG}                                HOFFMAN 2 - LLM                                    ${RESET}"

  # Middle separator
  echo -e "${BORDER_BG}══════════════════════════════════════════════════════════════════════════════════════${RESET}"

  # Subtext
  echo -e "${TEXT_COLOR}                      Welcome! Please make sure to follow the usage guidelines.        ${RESET}"

  # Quit message
  echo -e "${QUIT_MSG}                                                   Press ctrl+c to quit                ${RESET}"

  # Bottom border
  echo -e "${BORDER_BG}══════════════════════════════════════════════════════════════════════════════════════${RESET}"
}

# Call the banner function
print_banner
tput sgr0

# Capitalized color variables
CYAN=$'\e[1;36m'
BLUE=$'\e[1;34m'
GREEN=$'\e[1;32m'
YELLOW=$'\e[1;33m'
WHITE=$'\e[1;37m'
PURPLE=$'\e[1;35m'
RESET=$'\e[0m'
## USAGE ##
usage ()
{
  echo -e "${CYAN}#######################################################################################${RESET}"
  echo -e "${BLUE}##                              HOFFMAN2 LLM USAGE GUIDE                         ##${RESET}"
  echo -e "${CYAN}#######################################################################################${RESET}"

  echo -e "\n${GREEN}This script will create an RStudio session on a compute node on Hoffman2.${RESET}\n"

  echo -e "${YELLOW}REQUIRED OPTIONS:${RESET}"
  echo -e "  ${WHITE}-u${RESET} [username]    Your Hoffman2 username (mandatory)\n"

  echo -e "${YELLOW}OPTIONAL PARAMETERS:${RESET}"
  echo -e "  ${WHITE}-m${RESET} [MEMORY]     Memory requirements in GB (default: 10 GB)"
  echo -e "  ${WHITE}-t${RESET} [TIME]       Time of job in HH:MM:SS (default: 2:00:00)"
  echo -e "  ${WHITE}-p${RESET}              Request high-priority queue (highp)"
  echo -e "  ${WHITE}-g${RESET} [GPUTYPE]    Request GPU resources, where GPUTYPE can be 'V100', 'A100', A6000, etc."
  echo -e "  ${WHITE}-o${RESET} [UI_TYPE]    UI type (webui, jupyter). Default: basic ollama\n"

  echo -e "${PURPLE}HELP:${RESET}"
  echo -e "  ${WHITE}-h${RESET}              Show this usage message\n"

  echo -e "${CYAN}#######################################################################################${RESET}"
  exit
}

# Example: Uncomment this to test calling the usage function
# usage
## CLEANING UP ##
function cleaning()
{
    # Prevent multiple executions of cleaning function
    if [[ "$CLEANING_IN_PROGRESS" == "true" ]]; then
        return
    fi
    CLEANING_IN_PROGRESS=true
    
    # Temporarily disable trap to prevent re-entry
    trap '' INT
    
    echo "Cleaning up resources..."
    
    # Kill SSH port forwarding processes
    echo "Terminating SSH port forwarding..."
    pkill -f "ssh -N -L ${ollama_port}"
    
    # If we have a compute node hostname, try to stop the Apptainer instance
    if [[ -n "$out_host" ]]; then
        echo "Stopping Apptainer instance 'myollama' on $out_host..."
        
        # Use expect with better timeout handling
expect <<- eofend > llmtmp  &
set timeout $WALLTIME
spawn ssh ${H2USERNAME}@hoffman2.idre.ucla.edu
expect  {
        "assword:" { send "${H2PASSWORD}\r";exp_continue}
        send "export PS1='$ '\r"
        "$ " {send "ssh $out_host 'source /u/local/Modules/default/init/modules.sh && module load apptainer && apptainer instance stop myollama' \r";exp_continue}
        expect "$ "
        send "exit\r"
}
eofend

    fi
    
    # Remove temporary files
    if [ -f llmtmp ] ; then rm llmtmp ; fi
    echo "Cleanup complete. Exiting."
    exit 0
}

# Set traps for different signals to ensure cleanup happens
trap cleaning EXIT INT TERM

## GETTING COMMAND LINE OPTIONS ###
while getopts ":u:t:m:e:v:g:o:ph" options ; do
  case $options in
    h ) usage; exit ;;               # Show usage guide
    u ) H2USERNAME=$OPTARG  ;;        # Hoffman2 username
    t ) JOBTIME=$OPTARG ;;            # Job time
    m ) JOBMEM=$OPTARG ;;             # Job memory
    v ) RSTUDIO_VERSION=$OPTARG ;;    # RStudio version
    p ) HIGHP="TRUE" ;;               # Set high priority (HIGHP) to TRUE
    g ) GPUTYPE=$OPTARG ;;            # Set GPU type to the specified value
    o ) UI_TYPE=$OPTARG ;;            # Set UI type (webui, jupyter, etc.)
    : ) echo "-$OPTARG requires an argument"; usage; exit ;;  # Missing argument case
    ? ) echo "-$OPTARG is not an option"; usage ; exit ;;     # Unknown option case
  esac
done

## If -v wasn't provided, default to 4.1.0
if [ -z "${RSTUDIO_VERSION}" ] ; then
  RSTUDIO_VERSION="4.1.0"
fi

## CHECK FOR EXPECT ##
if ! command -v expect &> /dev/null
then
        echo "You MUST have the expect command installed on your system... Exiting"
        exit
fi

## CHECK ARGS ##

## CHECK USERNAME ##
if [ -z ${H2USERNAME} ] ; then
        echo "MUST ENTER Hoffman2 USER NAME"
        usage
fi

## CHECK MEM ##
if [ -z ${JOBMEM} ] ; then JOBMEM=10 ; fi

## CHECK RUN TIME ##
if [ -z ${JOBTIME} ] ; then JOBTIME="2:00:00" ; fi
WALLTIME=`echo "$JOBTIME" | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }'`

## CHECK FOR SSH PASSWORD

## PASSWORDLESS CHECK
echo "Checking for Hoffman2 password..."
if ! ssh -o BatchMode=yes "${H2USERNAME}@hoffman2.idre.ucla.edu" true 2>/dev/null; then
        echo "Please enter your Hoffman2 Password for User: ${H2USERNAME}"
        read -s H2PASSWORD
else
        H2PASSWORD=""
        PASSWORDLESS="true"
        PASSWORD_CHECK="true"
fi

if [[ "${PASSWORDLESS}"  != "true" ]] ; then
PASSWORD_CHECK=false
expect <<- eof3 > llmtmp  
set timeout $WALLTIME
spawn ssh -o NumberOfPasswordPrompts=1 ${H2USERNAME}@hoffman2.idre.ucla.edu
     expect "*assword:" 
     send "${H2PASSWORD}\r"
     expect "$ "
eof3
check_pass=`cat llmtmp | grep "Permission denied" | wc -l`
rm llmtmp
for itr in 1 2 3 ; do
if [[ "${check_pass}" -ne "0" ]] ; then
        echo "Incorrect Password: Please enter your Hoffman2 Password for User: ${H2USERNAME}"
        read -s H2PASSWORD
else
        PASSWORD_CHECK=true
        break
fi

expect <<- eof3 > llmtmp
set timeout $WALLTIME
spawn ssh -o NumberOfPasswordPrompts=1 ${H2USERNAME}@hoffman2.idre.ucla.edu
     expect "*assword:"
     send "${H2PASSWORD}\r"
     expect "$ "
eof3
check_pass=`cat llmtmp | grep "Permission denied" | wc -l`
rm llmtmp
done
if [[ "$PASSWORD_CHECK"  != "true" ]] ; then
        echo "Password is invaild"
        exit 1
fi
fi

## CHECK EXTRA ARGS ##
EXTRA_ARG=""
# Add "highp" if HIGHP is true
if [[ "$HIGHP" == "TRUE" ]]; then
  EXTRA_ARG+="highp,"
fi
# Add GPU type if GPUTYPE exists
if [[ -n "$GPUTYPE" ]]; then
  EXTRA_ARG+="${GPUTYPE},gpu,cuda=1,"
fi

## STARING RSTUDIO JOB ##
sleep 2
trap cleaning EXIT

qrsh_cmd=`echo 'source /u/local/Modules/default/init/modules.sh ; module purge ; module load apptainer ; module list ; echo HOSTNAME ; echo \\\$HOSTNAME ; apptainer instance run --nv \\\$H2_CONTAINER_LOC/h2-ollama-0.6.5-webui-0.6.2.sif  myollama ; echo  ollama_start ; sleep infinity'`
qrsh_cmd_webui=`echo 'source /u/local/Modules/default/init/modules.sh ; module purge ; module load apptainer ; module list ; echo HOSTNAME ; echo \\\$HOSTNAME ; apptainer instance run --nv \\\$H2_CONTAINER_LOC/h2-ollama-0.6.5-webui-0.6.2.sif  myollama openwebui ; echo  ollama_start ; sleep infinity'`
qrsh_cmd_jupyter=`echo 'source /u/local/Modules/default/init/modules.sh ; module purge ; module load apptainer ; module list ; echo HOSTNAME ; echo \\\$HOSTNAME ; apptainer instance run --nv \\\$H2_CONTAINER_LOC/h2-ollama-0.6.5-webui-0.6.2.sif  myollama jupyter ; echo  ollama_start ; sleep infinity'`

## SELECT COMMAND BASED ON UI TYPE ##
if [[ "$UI_TYPE" == "webui" ]]; then
  ssh_cmd="echo starting ; qrsh -N OLLAMA -l ${EXTRA_ARG}h_data=${JOBMEM}G,h_rt=${JOBTIME} '${qrsh_cmd_webui}'"
  webui_port=8081
elif [[ "$UI_TYPE" == "jupyter" ]]; then
  ssh_cmd="echo starting ; qrsh -N OLLAMA -l ${EXTRA_ARG}h_data=${JOBMEM}G,h_rt=${JOBTIME} '${qrsh_cmd_jupyter}'"
  jupyter_port=8888
else
  ssh_cmd="echo starting ; qrsh -N OLLAMA -l ${EXTRA_ARG}h_data=${JOBMEM}G,h_rt=${JOBTIME} '${qrsh_cmd_webui}'"
fi

# Export the ssh_cmd for use in the expect script
export ssh_cmd

expect <<- eof1 > llmtmp  &
set timeout $WALLTIME
spawn ssh ${H2USERNAME}@hoffman2.idre.ucla.edu
expect  {
        "assword:" { send "${H2PASSWORD}\r";exp_continue}
        send "export PS1='$ '\r"
        "$ " {send "$env(${ssh_cmd})\r";exp_continue}
        send "sleep $WALLTIME"
        expect "$ "
}
eof1

## CHECK if SSH WORKED ##
start_bool=`cat llmtmp | grep starting | wc -l`
while [[ ${start_bool} -eq 0 ]]; do
  sleep 1
  start_bool=`cat llmtmp | grep starting | wc -l`
done 

## WAITING FOR JOB TO START ##

spinner=("🔄" "🚀" "🌟" "🔥" "✨" "🌀" "💫")
printf "Waiting for ollama to start..."
while [[ ${out_tmp} -ne 2 ]]
do
  for emoji in "${spinner[@]}"; do
    printf "\r%s Waiting for ollama job to start on Hoffman2..." "$emoji" 
    out_tmp=`cat llmtmp | grep "ollama_start" | wc -l`
    sleep 0.3
  done
done
echo -e "\n🚀 Ollama is now ready!"

### OPEN UP PORT
out_host=$(awk '/HOSTNAME/{getline; print $1}' llmtmp | tail -1 | tr -d '\r' | tr -d '\n')
ollama_port=11434
out2="${ollama_port}:${out_host}:${ollama_port}"

echo "Hoffman2 compute node is ${out_host}"
echo "ollama_port is ${ollama_port}"

# Setup additional port forwarding based on UI type
if [[ "$UI_TYPE" == "webui" ]]; then
  webui_port=8081
  webui_mapping="${webui_port}:${out_host}:${webui_port}"
  echo "webui_port is ${webui_port}"
  
  # Port forwarding for both Ollama and WebUI
  expect <<- eof2 > /dev/null &
set timeout $WALLTIME
spawn ssh -N -L ${ollama_port}:${out_host}:${ollama_port} -L ${webui_port}:${out_host}:${webui_port} ${H2USERNAME}@hoffman2.idre.ucla.edu
     expect "*assword:"
     send "${H2PASSWORD}\r"
     expect "$ "
eof2
elif [[ "$UI_TYPE" == "jupyter" ]]; then
  jupyter_port=8888
  jupyter_mapping="${jupyter_port}:${out_host}:${jupyter_port}"
  echo "jupyter_port is ${jupyter_port}"
  
  # Port forwarding for both Ollama and Jupyter
  expect <<- eof2 > /dev/null &
set timeout $WALLTIME
spawn ssh -N -L ${ollama_port}:${out_host}:${ollama_port} -L ${jupyter_port}:${out_host}:${jupyter_port} ${H2USERNAME}@hoffman2.idre.ucla.edu
     expect "*assword:"
     send "${H2PASSWORD}\r"
     expect "$ "
eof2
else
  # Original port forwarding for Ollama only
  expect <<- eof2 > /dev/null &
set timeout $WALLTIME
spawn ssh -N -L ${ollama_port}:${out_host}:${ollama_port} ${H2USERNAME}@hoffman2.idre.ucla.edu
     expect "*assword:"
     send "${H2PASSWORD}\r"
     expect "$ "
eof2
fi

## OPENING UP BROWSER ##
spinner=("🌍" "🌎" "🌏" "🌕" "🌖" "🌗" "🌘")

if [[ "$UI_TYPE" == "webui" ]]; then

  # Wait for WebUI to be ready
  while ! curl -s -o /dev/null -w "%{http_code}" http://localhost:${webui_port} | grep -qE "200|302|403"
  do
    for emoji in "${spinner[@]}"; do
      printf "\r%s Waiting for WebUI job to start on Hoffman2..." "$emoji"
      sleep 0.3
    done
  done
  echo -e "\n🚀 WebUI is now ready at ${GREEN}http://localhost:${webui_port}${RESET}!"
  
  # Auto-open browser for WebUI
  if command -v xdg-open &> /dev/null; then 
    xdg-open http://localhost:${webui_port}
  elif command -v open &> /dev/null; then 
    open http://localhost:${webui_port}
  fi

elif [[ "$UI_TYPE" == "jupyter" ]]; then
  # Wait for Jupyter to be ready
  while ! curl -s -o /dev/null -w "%{http_code}" http://localhost:${jupyter_port} | grep -qE "200|302|403"
  do
    for emoji in "${spinner[@]}"; do
      printf "\r%s Waiting for Jupyter job to start on Hoffman2..." "$emoji"
      sleep 0.3
    done
  done
  echo -e "\n🚀 Jupyter is now ready ${GREEN}http://localhost:${jupyter_port}${RESET}!"

  # Auto-open browser for Jupyter
  if command -v xdg-open &> /dev/null; then 
    xdg-open http://localhost:${jupyter_port}
  elif command -v open &> /dev/null; then 
    open http://localhost:${jupyter_port}
  fi
fi
echo -e $"You can now access Ollama API at ${GREEN}http://localhost:${ollama_port}${RESET}"

### WAITING UNTIL WALLTIME ##
echo -e "\n ${YELLOW}Press ${RED}ctrl+c${YELLOW} to exit the script at any time!${RESET}"
sleep $WALLTIME

## WAITING FOR JOB TO START ##


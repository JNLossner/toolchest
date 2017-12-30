#!/bin/bash
#
# Rocket.Chat notification post-receive hook.
#
# Based on: https://github.com/chriseldredge/git-rocketchat-hook/blob/master/git-rocketchat-hook
#
# Settings needed:
#  git config hooks.rocketchat.webhook-url "https://www.mydomain.com/hooks/..."
#  git config hooks.rocketchat.channel "general"
#
# - The rocketchat webhook URL can be found in the Administration settings under Integrations.
#
function help() {
  echo "Required config settings:"
  echo "  git config hooks.rocketchat.webhook-url 'https://www.mydomain.com/hooks/...'"
  echo "  git config hooks.rocketchat.channel 'general'"
  echo "Optional config settings:"
  echo "  git config hooks.rocketchat.show-only-last-commit true"
  echo "  git config hooks.rocketchat.show-full-commit true"
  echo "  git config hooks.rocketchat.username 'git'"
  echo "  git config hooks.rocketchat.icon-url 'http://imgur/icon.png'"
  echo "  git config hooks.rocketchat.icon-emoji ':twisted_rightwards_arrows:'"
  echo "  git config hooks.rocketchat.repo-nice-name 'MyRepo'"
  echo "  git config hooks.rocketchat.repos-root '/path/to/repos'"
  echo "  git config hooks.rocketchat.changeset-url-pattern 'http://yourserver/%repo_path%/changeset/%rev_hash%'"
  echo "  git config hooks.rocketchat.compare-url-pattern 'http://yourserver/%repo_path%/changeset/%old_rev_hash%..%new_rev_hash%'"
  echo "  git config hooks.rocketchat.branch-regexp 'regexp'"
}

function replace_variables() {
  sed "s|%repo_path%|$repopath|g; s|%old_rev_hash%|$oldrev|g; s|%new_rev_hash%|$newrev|g; s|%rev_hash%|$newrev|g; s|%repo_prefix%|$repoprefix|g"
}

function notify() {
  oldrev=$(git rev-parse $1)
  newrev=$(git rev-parse $2)
  refname="$3"

  # --- Interpret
  # 0000->1234 (create)
  # 1234->2345 (update)
  # 2345->0000 (delete)
  if expr "$oldrev" : '0*$' >/dev/null
  then
    change_type="create"
  else
    if expr "$newrev" : '0*$' >/dev/null
    then
      change_type="delete"
    else
      change_type="update"
    fi
  fi

  # --- Get the revision types
  newrev_type=$(git cat-file -t $newrev 2> /dev/null)
  oldrev_type=$(git cat-file -t "$oldrev" 2> /dev/null)
  case "$change_type" in
    create|update)
      rev="$newrev"
      rev_type="$newrev_type"
      ;;
    delete)
      rev="$oldrev"
      rev_type="$oldrev_type"
      ;;
  esac

  # The revision type tells us what type the commit is, combined with
  # the location of the ref we can decide between
  #  - working branch
  #  - tracking branch
  #  - unannoted tag
  #  - annotated tag
  case "$refname","$rev_type" in
    refs/tags/*,commit)
      # un-annotated tag
      refname_type="tag"
      short_refname=${refname##refs/tags/}
      ;;
    refs/tags/*,tag)
      # annotated tag
      refname_type="annotated tag"
      short_refname=${refname##refs/tags/}
      # change recipients
      if [ -n "$announcerecipients" ]; then
        recipients="$announcerecipients"
      fi
      ;;
    refs/heads/*,commit)
      # branch
      refname_type="branch"
      short_refname=${refname##refs/heads/}
      ;;
    refs/remotes/*,commit)
      # tracking branch
      refname_type="tracking branch"
      short_refname=${refname##refs/remotes/}
      echo >&2 "*** Push-update of tracking branch, $refname"
      echo >&2 "***  - no notification generated."
      return 0
      ;;
    *)
      # Anything else (is there anything else?)
      echo >&2 "*** Unknown type of update to $refname ($rev_type)"
      echo >&2 "***  - no notification generated"
      return 0
      ;;
  esac

  branchregexp=$(git config --get hooks.rocketchat.branch-regexp)
  if [ -n "$branchregexp" ]; then
    if [[ ! $short_refname =~ $branchregexp ]]; then
      echo >&2 "No Notification because $short_refname does not match $branchregexp"
      return 0
    fi
  fi

  # plural suffix, default "", changed to "s" if commits > 1
  s=""

  # Repo name, either Gitolite or normal repo.
  if [ -n "$GL_REPO" ]; then
    # it's a gitolite repo
    repo="$GL_REPO"
  else
    repodir=$(basename "$(pwd)")
    if [ "$repodir" == ".git" ]; then
      repodir=$(dirname "$PWD")
      repodir=$(basename "$repodir")
    fi
    repo=${repodir%.git}
  fi

  repoprefix=$(git config hooks.rocketchat.repo-nice-name || git config hooks.irc.prefix || git config hooks.emailprefix || echo "$repo")
  onlylast=$(git config --get hooks.rocketchat.show-only-last-commit)
  onlylast=$onlylast && [ -n "$onlylast" ]
  fullcommit=$(git config --get hooks.rocketchat.show-full-commit)

  # Get the user information
  # If $GL_USER is set we're running under gitolite.
  if [ -n "$GL_USER" ]; then
    user=$GL_USER
  else
    user=$USER
  fi

  case ${change_type} in
    "create")
      header="New ${refname_type} *${short_refname}* has been created in ${repoprefix}"
      single_commit_suffix="commit"
      ;;
    "delete")
      header="$(tr '[:lower:]' '[:upper:]' <<< ${refname_type:0:1})${refname_type:1} *$short_refname* has been deleted from ${repoprefix}"
      single_commit_suffix="commit"
      ;;
    "update")
      num=$(git log --pretty=oneline ${1}..${2}|wc -l|tr -d ' ')
      branch=${3/refs\/heads\//}

      if [ ${num} -gt 1 ]; then
        header="${num} new commits *pushed* to *${short_refname}* in ${repoprefix}"
        single_commit_suffix="one"
        s="s"
      else
        header="A new commit has been *pushed* to *${short_refname}* in ${repoprefix}"
        single_commit_suffix="one"
      fi

      ;;
    *)
      # most weird ... this should never happen
      echo >&2 "*** Unknown type of update to $refname ($rev_type)"
      echo >&2 "***  - notifications will probably screw up."
      ;;
  esac

  if $onlylast && [[ "${change_type}" != "delete" ]]; then
    header="$header, showing last $single_commit_suffix:"
  fi


  if [[ "${change_type}" != "delete" && "${refname_type}" == "branch" ]]; then
    changeseturlpattern=$(git config --get hooks.rocketchat.changeset-url-pattern)
    compareurlpattern=$(git config --get hooks.rocketchat.compare-url-pattern)
    reporoot=$(git config --get hooks.rocketchat.repos-root)

    if [ -n "$reporoot" ]; then
      # Get absolute path
      reporoot=$(readlink -f $reporoot)
    fi

    urlformat=
    if [ -n "$changeseturlpattern" -a -n "$reporoot" ]; then
      if [[ $PWD == ${reporoot}* ]]; then
        repopath=$PWD
        base=$(basename $PWD)
        if [ "$base" == ".git" ]; then
          repopath=$(dirname $repopath)
        fi
        idx=$(echo $reporoot | wc -c | tr -d ' ')
        repopath=$(echo $repopath | cut -c$idx-)
        urlformat=$(echo $changeseturlpattern | replace_variables)

        if [ -n "$compareurlpattern" ]; then
          comparelink=$(echo $compareurlpattern | replace_variables)
          header=$(echo $header | sed -e "s|\([a-zA-Z0-9]\{1,\} new commit[s]\{0,1\}\)|\<$comparelink\|\\1\>|")
        fi
      else
        echo >&2 "$PWD is not in $reporoot. Not creating hyperlinks."
      fi
    fi

    formattedurl=""
    if [ -n "$urlformat" ]; then
      formattedurl="<${urlformat}|%h> "
    fi


    nl="\\\\n"

    if [[ "${change_type}" == "update" ]]; then
      start="${1}"
    else
      start="HEAD"
    fi

    end="${2}"


    # merge `git log` output with $header
    if $onlylast; then
      countarg="-n 1"
    else
      countarg=""
    fi

    # show the full commit message
    if [ "$fullcommit" == "true" ]; then
      commitformat="%s%n%n%b"
    else
      commitformat="%s"
    fi

    # Process the log and escape double quotes and backslashes; assuming commit names/messages don't have five of the following: & ; @
    log_out=$( git log --pretty=format:"&&&&&%cN %h;;;;;${formattedurl}${commitformat}@@@@@" $countarg ${start}..${end} \
        | sed -e 's/\\/\\\\\\\\/g;' \
        | sed -e 's/"/\\"/g' \
        | sed -e 's/^&&&&&\(.*\);;;;;/{\"title_link\":\"\", \"title\":\"\1\", \"text\":\"/' \
        | sed -e 's/@@@@@$/"},/' \
        | perl -p -e 's/},\n/}, /mg' )

    attachments="[${log_out%?}]"
  fi

  if [ -n "${attachments}" ] && [[ "${attachments}" != "" ]]; then
    msg=$(echo -e "\"text\":\"${header}\", \"attachments\": $attachments")
  else
    msg=$(echo -e "\"text\":\"${header}\"")
  fi

  # JSON uses \n substitution for newlines
  msg=$(echo -n "${msg}" | perl -p -e 's/,\]/]/mg')

  webhook_url=$(git config --get hooks.rocketchat.webhook-url)
  channel=$(git config --get hooks.rocketchat.channel)
  username=$(git config --get hooks.rocketchat.username)
  iconurl=$(git config --get hooks.rocketchat.icon-url)
  iconemoji=$(git config --get hooks.rocketchat.icon-emoji)

  if [ -z "$webhook_url" ]; then
    echo "ERROR: config settings not found"
    help
    exit 1
  fi

  payload="{${msg}"

  if [ -n "$channel" ]; then
    payload="$payload, \"channel\": \"$channel\""
  fi

  if [ -n "$username" ]; then
    payload="$payload, \"username\": \"$username\""
  fi

  if [ -n "$iconurl" ]; then
    payload="$payload, \"icon_url\": \"$iconurl\""
  elif [ -n "$iconemoji" ]; then
    payload="$payload, \"icon_emoji\": \"$iconemoji\""
  fi

  payload="$payload}"

  if [ -n "$DEBUG" ]; then
    echo "POST $webhook_url"
    echo "payload=$payload"
    return 0
  fi

  curl -X POST -H "Content-Type: application/json" --data "$payload" "$webhook_url" >/dev/null
}

################################################################################
# MAIN PROGRAM
# Read all refs from stdin, notify rocketchat for each
################################################################################
if [ -z "$GIT_DIR" ]; then
  help
  exit 1
fi

while read line; do
  set -- $line
  notify $*
  RET=$?
done

exit $RET

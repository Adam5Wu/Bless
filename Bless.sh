#!/bin/bash

# Constants
REVZERO="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
BUILDDIR="build"
BLESSDIR="${BUILDDIR}/blessed"
BLESSCFG=".bless.config"
BLESSWT=".bless.keyed"
BLESSWOT=".bless.unkeyed"
BLESSNOT=".bless.blacklist"
BLESSPKG="Source.Blessed"

# Environmental sanity check
[ ${BASH_VERSION%%.*} -lt 4 ] && echo "Require bash version 4 and up!" && exit 1
TOOLS=( git sed cut unix2dos tar )
for t in ${TOOLS[@]}; do
	which "$t" >/dev/null || { echo "Utility '$t' not found!"; exit 2; }
done
# Check annotated tags
git describe 1>/dev/null 2>&1 || {
	# Backup plan, check any tag
	git describe --tags 1>/dev/null 2>&1 || {
		echo "HINT: Use tags to help you better organize version history!";
	}
	echo "HINT: Use annotated tags to maximize the benefit of using this tool!";
}

# Pull parameters
KEYPFX=
[ $# -ge 1 ] && KEYPFX="$1"
TAGFROM=
[ $# -ge 2 ] && TAGFROM="$2"
SORTFIELD=2r
[ $# -ge 3 ] && SORTFIELD="$3"

# Parameter sanity check
if [ -z "$TAGFROM" ]; then
	# Try to get the last annotated tag
	TAGFROM=`git describe --abbrev=0 2>/dev/null`
	# If not available, fallback to any tag
	[ -z "$TAGFROM" ] && TAGFROM=`git describe --tags --abbrev=0 2>/dev/null`
	# If still not available, fallback to the beginning of repo
	[ -z "$TAGFROM" ] && TAGFROM="$REVZERO" || {
		# If we got a tag, check if we are at the tag itself
		TAGCUR=`git describe --tags`
		# If so, walk back to previous annotated tag
		[ "$TAGFROM" == "$TAGCUR" ] && TAGFROM=`git describe --abbrev=0 ${TAGCUR}^ 2>/dev/null`
		# If not available, fallback to walk back to previous any tag
		[ -z "$TAGFROM" ] && TAGFROM=`git describe --tags --abbrev=0 ${TAGCUR}^ 2>/dev/null`
		# If failed again, fallback to beginning of repo
		[ -z "$TAGFROM" ] && TAGFROM="$REVZERO"
	}
else
	# If special symbol is used, start from beginning of repo
	[ "$TAGFROM" == '^' ] && TAGFROM="$REVZERO" || {
		# Otherwise, assume it is a valid tag or hash, probe the repo
		ALTTAGFROM=`git describe --tags --always ${TAGFROM} 2>/dev/null`
		[ -z "$ALTTAGFROM" ] && { echo "ERROR: Invalid origin tag '${TAGFROM}'"; exit 3; }
		TAGFROM="$ALTTAGFROM"
	}
fi
[ "$TAGFROM" == "$REVZERO" ] && echo "Blessing from the very beginning..." || echo "Blessing from revision '${TAGFROM}'..."

FLUSH=0
mkdir -p ${BUILDDIR}
# Load previous profile
[ -f "${BUILDDIR}/${BLESSCFG}" ] && . ${BUILDDIR}/${BLESSCFG} || FLUSH=X

[ "$_KEYPFX" != "$KEYPFX" ] && FLUSH=1
[ "$_TAGFROM" != "$TAGFROM" ] && FLUSH=2
[ "$_SORTFIELD" != "$SORTFIELD" ] && FLUSH=3

# Check if previous generated files need to be flushed
[ "$FLUSH" != "0" ] && {
	rm -rf ${BLESSDIR}
	echo -e "_KEYPFX=\"$KEYPFX\"\n_TAGFROM=\"$TAGFROM\"\n_SORTFIELD=\"$SORTFIELD\"" > ${BUILDDIR}/${BLESSCFG}
	rm -rf ${BUILDDIR}/${BLESSWT}
	rm -rf ${BUILDDIR}/${BLESSWOT}
}

# Create blessed directory (if not exists)
mkdir -p ${BLESSDIR}

# Load previous tagged and untagged file list (if exists)
declare -A KEYED
[ -f ${BUILDDIR}/${BLESSWT} ] && while read f; do KEYED["$f"]=0; done < ${BUILDDIR}/${BLESSWT}
declare -A UNKEYED
[ -f ${BUILDDIR}/${BLESSWOT} ] && while read f; do UNKEYED["$f"]=0; done < ${BUILDDIR}/${BLESSWOT}

# Load black list
BLACKLIST=()
[ -f ${BUILDDIR}/${BLESSNOT} ] && {
	readarray -t BLACKLIST < "${BUILDDIR}/${BLESSNOT}"
	for b in "${BLACKLIST[@]}"; do [ ! -z "$b" ] && echo "Black-list: $b"; done
} || touch "${BUILDDIR}/${BLESSNOT}"

trap "echo 'WARNING: Bless aborted, invalidating whole cache...'; rm -f ${BUILDDIR}/${BLESSCFG}; exit -1" SIGHUP SIGINT SIGTERM

# Get all files under VCS
readarray -t ALLFILES < <( git ls-tree --name-only -r HEAD )

declare -A BLESSED
CHANGED=()
# For each file, generate the blessed version
for f in "${ALLFILES[@]}"; do
	SKIP=
	# Detect submodule
	[ -d "$f" ] && {
		echo "Bypassing submodule '$f'..."
		SKIP="M:$f"
	}

	[ -z "$SKIP" ] && {
		# Check black list
		BLACKLISTED=
		for b in "${BLACKLIST[@]}"; do
			[ ! -z "$b" ] && {
				[ "${f:0:${#b}}" == "$b" ] && BLACKLISTED="$b" && break
			}
		done
		[ ! -z "$BLACKLISTED" ] && {
			#echo "Bypassing black-listed file '$f'..."
			SKIP="B:$f"
		}
	}

	# Process file skipping
	[ ! -z "$SKIP" ] && {
		[ ${KEYED["$f"]+1} ] && CHANGED+=("ST:$f") && unset KEYED["$f"]
		[ ${UNKEYED["$f"]+1} ] && CHANGED+=("SU:$f") && unset UNKEYED["$f"]
		continue
	}

	# Skip if blessed file exists and is newer than original
	fbless=
	case "${f##*.}" in
	java|c|cpp|h|hpp)
		fbless="${BLESSDIR}/$f"
	;;
	*)
		fbless="${BLESSDIR}/$f.blessed"
	;;
	esac
	[ -f "$fbless" -a "$fbless" -nt "$f" ] && {
		#echo "Bypassing unmodified file '$f'..."
		BLESSED["$fbless"]=0
		continue
	}

	CHANGED+=("B:$f")
	BLESSED["$fbless"]=1
	# Detect whether git thinks the file is binary
	CHG=`git diff 4b825dc642cb6eb9a060e54bf8d69288fbee4904 --numstat HEAD -- "$f" | cut -f1`
	[ "$CHG" == "-" ] && {
		echo "Skipping binary '$f'..."
		mkdir -p "`dirname "$fbless"`"
		echo "(No blessings for binary data)" > "$fbless"
		continue
	}

	echo "Blessing '$f'..."
	# Gather the involved revisions
	REVS=( `git blame -b -s -w $TAGFROM.. -- "$f" | cut -d' ' -f1 | sort | uniq` )
	# Gather revision logs
	COMMITS=`for r in ${REVS[@]}; do [ ! -z "$r" ] && echo -n "[$r] " && git log --oneline --pretty=tformat:"%cd (%cn)%x09%s" --date=short -n 1 "$r"; done`
	# Generate real blame file
	mkdir -p "`dirname "$fbless"`"
	git blame -b -s -w $TAGFROM.. -- "$f" > "$fbless"

	# Uniform tagging handling
	UNKEY="N/A"
	if [ ! -z "$COMMITS" -a ! -z "$KEYPFX" ]; then
		UNKEY=
		readarray -t KEYS < <( echo "$COMMITS" | cut -f2- )
		KEYPFXLEN=${#KEYPFX}
		MAXLEN=0
		for (( i=0; i<${#KEYS[@]}; i++ )); do
			KEY=`echo "${KEYS[$i]}" | cut -d' ' -f1`
			[ "${KEY:0:$KEYPFXLEN}" != "$KEYPFX" ] && {
				echo "WARNING: Unkeyed message '${KEYS[$i]}'"
				KEY="$KEYPFX?"
				UNKEY="$f"
			}
			LEN=${#KEY}
			[ $LEN -gt $MAXLEN ] && MAXLEN=$LEN
			KEYS[$i]=$KEY
		done
		for (( i=0; i<${#KEYS[@]}; i++ )); do
			KEYS[$i]=`printf "%-${MAXLEN}s" ${KEYS[$i]}`
		done
		for (( i=0; i<${#KEYS[@]}; i++ )); do
			sed -i -e "s/^${REVS[$i]}/${REVS[$i]} ${KEYS[$i]}/" "$fbless"
		done
		sed -i -e "s/^ /  `printf "%${MAXLEN}s" ''`/" "$fbless"
	fi

	# Sort comment logs
	COMMITS=`echo "$COMMITS" | sort -k $SORTFIELD`

	# Update bless tagging status
	[ -z "$COMMITS" ] && { unset KEYED["$f"]; unset UNKEYED["$f"]; }
	[ ! -z "$COMMITS" ] && { [ -z "$UNKEY" ] && {
		unset UNKEYED["$f"]; KEYED["$f"]=1
	} || {
		unset KEYED["$f"]; UNKEYED["$f"]=1
	} }

	# Optionally produce compilable source code for certain languages that supports block comments
	case "${f##*.}" in
	java|c|cpp|h|hpp)
		sed -i -e '/\/\*\(\(?!\*\/\).\)*$/,/\*\// { /\/\*/n; s/^/`/ }' "$fbless"
		sed -i -e 's/^\([^`][^)]\+)\)/\/* \1 *\//' "$fbless"
		sed -i -e 's/^`\([^)]\+)\)/ * \1 * /' "$fbless"
		[ ! -z "$COMMITS" ] && ( echo && echo "---- Commit Logs ----" && echo "$COMMITS" ) | sed 's/^\(.\)/\/\/ \1/' >> "$fbless"
	;;
	*)
		[ ! -z "$COMMITS" ] && ( echo && echo "---- Commit Logs ----" && echo "$COMMITS" ) >> "$fbless"
	;;
	esac

	# Covert to DOS new line style to maximumize audiences
	unix2dos "$fbless" 2>/dev/null
done

# Remove blessed version of any stale files
readarray -t BLSFILES < <( find "${BLESSDIR}" -type f )
for f in "${BLSFILES[@]}"; do
	[ -z "${BLESSED[$f]}" ] && {
		CHANGED+=("D:$f")
		echo "Removing stale bless '$f'..."
		rm -f "$f"
	}
done

# Remove stale files in tagging status
for f in "${!KEYED[@]}"; do [ ! -f "$f" ] && { CHANGED+=("DT:$f"); unset KEYED["$f"]; } done 
for f in "${!UNKEYED[@]}"; do [ ! -f "$f" ] && { CHANGED+=("DU:$f"); unset UNKEYED["$f"]; } done 

[ ${#CHANGED[@]} -ne 0 ] && {
	# Update tagging status files
	echo -n > ${BUILDDIR}/${BLESSWT}
	for f in "${!KEYED[@]}"; do echo "$f" >> ${BUILDDIR}/${BLESSWT}; done
	echo -n > ${BUILDDIR}/${BLESSWOT}
	for f in "${!UNKEYED[@]}"; do echo "$f" >> ${BUILDDIR}/${BLESSWOT}; done

	# Prepare a compress package containing the blames
	echo "Generating blessed source package..."
	( cd ${BLESSDIR} && tar -cz --xform s:'./':: -f ../${BLESSPKG}.tgz . "../${BLESSWT}" "../${BLESSWOT}" "../${BLESSNOT}" 2>/dev/null )
} || echo "No change from previous bless"


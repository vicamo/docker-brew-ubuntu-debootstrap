#!/bin/bash
set -eo pipefail

cd "$(readlink -f "$(dirname "$BASH_SOURCE")")"

get_part() {
	local dir="$1"
	shift
	local part="$1"
	shift
	if [ -f "$dir/$part" ]; then
		cat "$dir/$part"
		return 0
	fi
	if [ -f "$part" ]; then
		cat "$part"
		return 0
	fi
	if [ $# -gt 0 ]; then
		echo "$1"
		return 0
	fi
	return 1
}

: ${sudo:=sudo}
declare -a envs
# contrib/mkimage.sh
envs+=(TMPDIR)
# contrib/mkimage/debootstrap
envs+=(DEBOOTSTRAP DONT_TOUCH_SOURCES_LIST)
for var in "${envs[@]}"; do
	eval value=\$$var
	[ -z "$value" ] || sudo="$sudo $var=$value"
done

repo="$(get_part . repo '')"
if [ "$repo" ]; then
	if [[ "$repo" != */* ]]; then
		user="$(docker info | awk '/^Username:/ { print $2 }')"
		if [ "$user" ]; then
			repo="$user/$repo"
		fi
	fi
fi

latest="$(get_part . latest '')"

args=( "$@" )
if [ ${#args[@]} -eq 0 ]; then
	args=( */ )
fi

suites=()
for arg in "${args[@]}"; do
	arg=${arg%/}
	arch=$(echo $arg | cut -d / -f 2)
	suite=$(echo $arg | cut -d / -f 1)
	if [ "$arch" == "$suite" ]; then
		arch=
	fi

	if [ -z "`echo ${suites[@]} | grep $suite`" ]; then
		suites+=( $suite )
	fi

	name=arches_$suite
	if [ "$arch" ]; then
		eval arches=\( \${${name}[@]} \)
		if [ ${#arches[@]} -ne 0 ]; then
			if [ -z "`echo ${arches[@]} | grep $arch`" ]; then
				eval $name+=\( "$arch" \)
			fi
		else
			eval $name=\( "$arch" \)
		fi
	else
		arches=( $suite/*/ )
		arches=( "${arches[@]%/}" )
		arches=( "${arches[@]#$suite/}" )
		if [ ${#arches[@]} -lt 0 -o "${arches[0]}" != "*" ]; then
			eval $name=\( "${arches[@]}" \)
		fi
	fi

	#echo "arch: $arch, suite: $suite"
	#echo "suites: ${suites[@]}"
	#eval echo "$name: \${${name}[@]}"
	#echo
done

tasks=()
for suite in "${suites[@]}"; do
	name=arches_$suite
	eval arches=\( \${${name}[@]} \)
	for arch in "${arches[@]}"; do
		dir="$(readlink -f "$suite/$arch")"

		skip="$(get_part "$dir" skip '')"
		if [ -n "$skip" ]; then
			echo "Skipping $suite/$arch, reason: $skip"
			continue
		fi

		tasks+=( $suite/$arch )
	done
done

for task in "${tasks[@]}"; do
	suite=$(echo $task | cut -d / -f 1)
	arch=$(echo $task | cut -d / -f 2)
	dir="$(readlink -f "$task")"
	variant="$(get_part "$dir" variant 'minbase')"
	components="$(get_part "$dir" components 'main')"
	include="$(get_part "$dir" include '')"
	version="$(get_part "$(readlink -f "$suite")" version "$suite")"
	mirror="$(get_part "$dir" mirror '')"
	script="$(get_part "$dir" script '')"

	args=( -d "$dir" debootstrap --arch="$arch" )
	[ -z "$variant" ] || args+=( --variant="$variant" )
	[ -z "$components" ] || args+=( --components="$components" )
	[ -z "$include" ] || args+=( --include="$include" )

	debootstrapVersion="$(dpkg-query -W -f '${Version}' debootstrap)"
	if dpkg --compare-versions "$debootstrapVersion" '>=' '1.0.69'; then
		args+=( --force-check-gpg )
	fi

	args+=( "$suite" )
	if [ "$mirror" ]; then
		args+=( "$mirror" )
		if [ "$script" ]; then
			args+=( "$script" )
		fi
	fi

	mkimage="$(readlink -f "${MKIMAGE:-"mkimage.sh"}")"
	{
		echo "$(basename "$mkimage") ${args[*]/"$dir"/.}"
		echo
		echo 'https://github.com/docker/docker/blob/master/contrib/mkimage.sh'
	} > "$dir/build-command.txt"

	${sudo} nice ionice -c 3 "$mkimage" "${args[@]}" 2>&1 | tee "$dir/build.log"

	${sudo} chown -R "$(id -u):$(id -g)" "$dir"

	if [ "$repo" ]; then
		( set -x && docker build -t "${repo}:${suite}-${arch}" "$dir" )

		tags=()
		[ "${arch}" = "amd64" ] && tags+=( "${suite}" )
		if [ "$suite" != "${version}" ]; then
			tags+=( "${version}-${arch}" )
			[ "${arch}" = "amd64" ] && tags+=( "${version}" )
		fi
		if [ "${suite}" = "${latest}" ]; then
			tags+=( "latest-${arch}" )
			[ "${arch}" = "amd64" ] && tags+=( "latest" )
		fi
		{
			set -x
			for tag in "${tags[@]}"; do
				docker tag -f "${repo}:${suite}-${arch}" "${repo}:${tag}"
			done
		}
		docker run -it --rm "${repo}:${suite}-${arch}" bash -xc '
			cat /etc/apt/sources.list
			echo
			cat /etc/os-release 2>/dev/null
			echo
			cat /etc/lsb-release 2>/dev/null
			echo
			cat /etc/debian_version 2>/dev/null
			true
		'
		docker run --rm "${repo}:${suite}-${arch}" dpkg-query -f '${Package}\t${Version}\n' -W > "$dir/build.manifest"
	fi
done

#!/bin/bash
set -e

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

declare -A aliases
aliases=(
	[$(cat latest)]='latest'
)

versions=( */ )
versions=( "${versions[@]%/}" )
url='git://github.com/tianon/docker-brew-ubuntu-debootstrap'

echo '# maintainer: Tianon Gravi <admwiggin@gmail.com> (@tianon)'

commitRange='master..dist'
commitCount="$(git rev-list "$commitRange" --count 2>/dev/null || true)"
if [ "$commitCount" ] && [ "$commitCount" -gt 0 ]; then
	echo
	echo '# commits:' "($commitRange)"
	git log --format=format:'- %h %s%n%w(0,2,2)%b' "$commitRange" | sed 's/^/#  /'
fi

for version in "${versions[@]}"; do
	commit="$(git log -1 --format='format:%H' "$version")"
	versionAliases=()
	fullVersion="$(tar -xvf "$version/rootfs.tar.xz" etc/debian_version --to-stdout 2>/dev/null)"
	if [ -z "$fullVersion" ] || [[ "$fullVersion" == */sid ]]; then
		fullVersion="$(eval "$(tar -xvf "$version/rootfs.tar.xz" etc/os-release --to-stdout 2>/dev/null)" && echo "$VERSION" | cut -d' ' -f1)"
		if [ -z "$fullVersion" ]; then
			# lucid...
			fullVersion="$(eval "$(tar -xvf "$version/rootfs.tar.xz" etc/lsb-release --to-stdout 2>/dev/null)" && echo "$DISTRIB_DESCRIPTION" | cut -d' ' -f2)" # DISTRIB_DESCRIPTION="Ubuntu 10.04.4 LTS"
		fi
	else
		while [ "${fullVersion%.*}" != "$fullVersion" ]; do
			versionAliases+=( $fullVersion )
			fullVersion="${fullVersion%.*}"
		done
	fi
	if [ "$fullVersion" != "$version" ]; then
		versionAliases+=( $fullVersion )
	fi
	versionAliases+=( $version $(cat "$version/suite" 2>/dev/null || true) ${aliases[$version]} )
	
	echo
	for va in "${versionAliases[@]}"; do
		echo "$va: ${url}@${commit} $version"
	done
done

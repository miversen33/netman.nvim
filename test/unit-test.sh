# For some reason flags (init and write?) cause a core dump
i=1
flags=""
for flag in "$@"
do
    flags="$flags -t $flag"
done
busted -m "../?.lua" --helper lua.netman.tools.bootstrap * $flags

i=1
flags=""
for flag in "$@"
do
    flags="$flags -t $flag"
done
# TODO: Figure out how to run this regardless of the directory its run from...?
busted -m "../?.lua"  --keep-going --helper lua.netman.tools.bootstrap ./core/ ./behavioral/ ./regression/ $flags

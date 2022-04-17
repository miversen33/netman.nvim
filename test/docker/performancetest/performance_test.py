#!/usr/bin/python3
from subprocess import run
import re

iterations = 500
important_log_lines = ['netman.nvim', 'netrwPlugin.vim']
time_regex = re.compile('^[\d\.]+\s+([\d\.]+)')
netman_time = 0
netrw_time = 0
run('rm -rf /tmp/output_dir/', shell=True)
run('mkdir -p /tmp/output_dir/', shell=True)
for iteration in range(iterations):
    command = f'$NEOVIM_DIRECTORY/bin/./nvim -u $NEOVIM_PLUGIN_HOME/netman.nvim/test/minimal-performance-config.vim --startuptime /tmp/output_dir/{iteration}.txt'
    run(command, shell=True)

for iteration in range(iterations):
    _in_file = f'/tmp/output_dir/{iteration}.txt'
    with open(_in_file, 'r') as in_file:
        for line in in_file.readlines():
            line = line.rstrip()
            for important_log in important_log_lines:
                if important_log in line:
                    _time = time_regex.match(line)
                    if not _time:
                        continue
                    _time = _time.groups()[0]
                    if important_log == important_log_lines[0]:
                        netman_time += float(_time)
                    else:
                        netrw_time += float(_time)
average_netman_time = netman_time / (iterations + .01 - .01)
average_netrw_time = netrw_time / (iterations + .01 - .01)

print(f"netman took on average {average_netman_time} ms to load")
print(f"netrw took on average {average_netrw_time} ms to load")
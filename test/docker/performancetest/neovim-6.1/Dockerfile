FROM ubuntu:20.04 AS neovim-0.6.1
RUN apt-get update -y && apt-get install wget tar git -y && apt-get clean -y
ENV NEOVIM_PLUGIN_HOME "/root/.local/share/nvim/site/pack/plugins/opt"
ENV NEOVIM_DIRECTORY   "/tmp/nvim-linux64"
RUN \
    echo "Updating Mirrors" \
    && apt-get update \
    && echo "Downloading neovim 0.6.1" \ 
    && wget -O /tmp/nvim-linux64.tar.gz https://github.com/neovim/neovim/releases/download/v0.6.1/nvim-linux64.tar.gz \
    && tar -C /tmp/ -xzf /tmp/nvim-linux64.tar.gz \
    && apt-get install -y python3 \
    && echo "Setting up netman plugin" \
    && touch /tmp/log.txt \
    && echo "Starting performace test for netman!" > /tmp/log.txt
CMD tail -f /tmp/log.txt
#!/bin/bash

CONFIG_DIR="$HOME/.config"
NVIM_DIR="$CONFIG_DIR/nvim"

npm install --global yarn -y

# Setup config folder
mkdir -p "$HOME/.config"

# https://github.com/mpcarolin/kickstart.nvim 
sudo add-apt-repository ppa:neovim-ppa/unstable -y
sudo apt update -y
sudo apt install make gcc ripgrep unzip git xclip neovim -y

# Needed for some plugins, like rest.nvim
sudo apt install luarocks -y

# clone the kickstart
git clone https://github.com/mpcarolin/kickstart.nvim "$NVIM_DIR"

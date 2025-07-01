#!/bin/bash

# Needed for some plugins, like rest.nvim
sudo apt install luarocks

# Installing docker
# TODO:
#
## Add user to docker group so you don't need to use sudo with every command
sudo usermod -aG docker $USER

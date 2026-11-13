-- herdr-nvim: send code annotations / file:line refs from nvim to an agent in
-- the herdr workspace. The sidebar + file picker half is a herdr plugin
-- (`herdr plugin install ChmaraX/herdr-nvim`, keys in herdr/config.toml).
--
-- Prefix moved off the default <leader>a, which is harpoon's "add file".
return {
  'ChmaraX/herdr-nvim',
  opts = {
    prefix = '<leader>H',
  },
}

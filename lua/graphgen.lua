local M = {}

function M.init()
	vim.api.nvim_create_autocmd("User", {
		pattern = "TSUpdate",
		callback = function()
			require("nvim-treesitter.parsers").graph = {
				install_info = {
					url = "https://github.com/UVARocketry/graphgen",
					files = { "tree-sitter-graph/src/parser.c" },
					generate = false,
				},
			}
		end,
	})
end

return M

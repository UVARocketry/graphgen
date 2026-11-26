local M = {}

function M.setup()
	vim.filetype.add({
		extension = { graph = "graph" },
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "TSUpdate",
		callback = function()
			require("nvim-treesitter.parsers").graph = {
				install_info = {
					url = "https://github.com/UVARocketry/graphgen",
					files = { "src/parser.c" },
					location = "tree-sitter-graph",
					generate = false,
				},
			}
		end,
	})
end

return M

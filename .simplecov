require 'simplecov-json'

SimpleCov.coverage_dir ".coverage"

unless !ENV["SIMPLECOV_HTML"].nil? && ENV["SIMPLECOV_HTML"] != "0"
	# Override the `simplecov-json`-provided formatter to write file into a different location, as we want to do some post-processing on the file but have the final result be `coverage.json`.
	# The other "intermediate" coverage files produced by `bashcov` use the `.{filename}.json` format, so do the same here.
	class SimpleCov::Formatter::IntermediateJsonFormatter < SimpleCov::Formatter::JSONFormatter
		def output_filename
			'.coverage.json'
		end
	end

	# Override the `simplecov` formatter to also write overall coverage summary information using a (modified) formatter from `simplecov-json`.
	# The default without this is to only present the overall coverage information (such as percentage covered) in an HTML output.
	SimpleCov.formatter = SimpleCov::Formatter::IntermediateJsonFormatter
end

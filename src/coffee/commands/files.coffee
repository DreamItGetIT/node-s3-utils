program = require 'commander'

program
.command 'upload', 'Upload file'
.command 'delete', 'Delete files'
.parse process.argv

program.help() unless program.args.length

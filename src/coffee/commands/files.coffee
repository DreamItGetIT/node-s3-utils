program = require 'commander'
Helpers = require '../helpers'

program
.command 'upload', 'Upload file'
.command 'delete', 'Delete files'
.parse process.argv

program.on '--help', Helpers.logo

program.help() unless program.args.length

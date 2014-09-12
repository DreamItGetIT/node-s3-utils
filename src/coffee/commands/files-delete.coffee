debug = require('debug')('s3utils-files-delete')
_ = require 'underscore'
program = require 'commander'
Promise = require 'bluebird'
Helpers = require '../helpers'
S3Client = require '../services/s3client'
{CustomError} = require '../errors'

program
.option '-c, --credentials <path>', 'set s3 credentials file path'
.option '-p, --prefix <name>', 'all files matching the prefix will be loaded'
.option '-r, --regex [name]', 'an optional RegExp used for filtering listed files (e.g.: /(.*)\.jpg/)', ''
.option '-l, --logFile <path>', 'optionally log to a file instead of printing to console (errors will still be printed to stderr)'
.option '--dry-run', 'list all files that will be deleted, but don\'t delete them', false
.parse process.argv

debug 'parsing args: %s', process.argv
Logger = require('../logger')(program.logFile)

try
  loadedCredentials = Helpers.loadCredentials(program.credentials)
  debug 'loaded credentials: %j', loadedCredentials

  if loadedCredentials and program.prefix

    s3client = new S3Client loadedCredentials

    Logger.info 'Fetching files...'
    s3client.filteredList {prefix: program.prefix}, program.regex
    .then (files) ->

      if program.dryRun
        debug 'running is dry-run mode, no files will be deleted'
        Logger.data 'Following files will be deleted (if run without dry mode)', files
      else
        if _.size(files) > 0
          Logger.info 'About to delete files...'
          bar = Logger.progress "Deleting files:\t[:bar] :percent, :current of :total files done (time: elapsed :elapseds, eta :etas)", _.size(files)
          bar.update(0)
          s3client.on 'progress', -> bar.tick()

          Promise.map files, (file) ->
            debug 'about to delete file %s', file.Key
            s3client.deleteFile file.Key
            .then -> Promise.resolve s3client.emit 'progress'
          , {concurrency: 5}
          .then ->
            Logger.info 'Files successfully deleted'
            process.exit 0
          .catch (error) ->
            Logger.error error.message
            process.exit 1
        else
          Logger.info 'No files to be deleted'
          process.exit 0
  else
    Logger.error 'Missing required arguments'
    program.help()
catch e
  if e instanceof CustomError
    Logger.error e.message
    process.exit 1
  else
    throw e

debug = require('debug')('s3utils-s3client')
{EventEmitter} = require('events')
_ = require 'underscore'
path = require 'path'
knox = require 'knox'
Lynx = require 'lynx'
Promise = require 'bluebird'
gm = require 'gm'
{CustomError} = require '../errors'
fs = Promise.promisifyAll require('fs')
S3Lister = require 's3-lister'

DEFAULT_IMG_EXTENSION = 'jpg'

###*
 * An S3Client wrapper that holds some useful methods to talk to S3
###
class S3Client

  ###*
   * Creates a new S3Client instance
   * @constructor
   * @param  {Object} opts A JSON object containing required information
   *
   * (internally initializes a `knoxClient`)
   * {@link https://github.com/LearnBoost/knox}
  ###
  constructor: (opts = {}) ->
    {key, secret, bucket, logger, metrics, resizeDetailsFileName} = opts
    throw new CustomError 'Missing AWS \'key\'' unless key
    throw new CustomError 'Missing AWS \'secret\'' unless secret
    throw new CustomError 'Missing AWS \'bucket\'' unless bucket

    @_logger = logger
    @_ee = new EventEmitter()

    @_knoxClient = knox.createClient
      key: key
      secret: secret
      bucket: bucket
    @_knoxClient = Promise.promisifyAll @_knoxClient

    if metrics?.active
      @_logger?.info 'StatsD metrics are enabled'
      @_metricsPrefix = metrics.prefix
      @_metrics = new Lynx 'localhost', 8125,
        on_error: -> #noop
    else
      @_metrics = undefined
    if resizeDetailsFileName?
      that = @
      @_resizeDetailsStream = fs.createWriteStream(resizeDetailsFileName)
      @_resizeDetailsStream.write("id\tpostfix\twidth\theight\n")
    else
      @_resizeDetailsStream = undefined

  on: (eventName, cb) -> @_ee.on eventName, cb
  emit: (eventName, obj) -> @_ee.emit eventName, obj
  sendMetrics: (typ, key) ->
    return unless @_metrics
    prefix = if @_metricsPrefix then "#{@_metricsPrefix}." else ''
    switch typ
      when 'increment' then @_metrics.increment "#{prefix}#{key}"
  storeResizeDetails: (filename, postfix, dimensions) ->
    return unless @_resizeDetailsStream
    @_resizeDetailsStream.write([
      filename.match(/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/)[0],
      postfix,
      dimensions.width,
      dimensions.height
    ].join("\t") + "\n")


  ###*
   * Lists all files in the given bucket
   * @param  {Object} headers The request headers for AWS (S3)
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  list: (headers) ->
    @sendMetrics 'increment', 'file.list'
    lister = new S3Lister @_knoxClient, headers
    files = []
    new Promise (resolve, reject) ->
      lister.on('data', (file) ->
        files.push(file)
      )
      lister.on('error', reject)
      lister.on('end', ->
        resolve(files)
      )

  ###*
   * Lists all files in the given bucket, filtering by an optional regex
   * @param  {Object} headers The request headers for AWS (S3)
   * @param  {String} [regex] A regular expression to filter the returned list
   * @param  {Boolean} [rejectFolders] Whether to reject folders from the returned list (default: true)
   * @return {Promise} A promise, fulfilled with the filtered list or rejected with an error
  ###
  filteredList: (headers, regex, rejectFolders = true) ->
    @list headers
    .then (files) ->
      debug 'listing %s files', files.length
      files = _.reject files, (content) ->
        if rejectFolders then content.Size is 0 else false

      if regex
        # filter files from given regex
        r = new RegExp regex, 'gi'
        debug 'using RegExp %s', regex
        filtered = _.filter files, (content) -> content.Key.match(r)
        debug 'filtered %s files', filtered.length
        Promise.resolve(filtered)
      else
        debug 'no regex defined, skipping filter'
        Promise.resolve(files)

  ###*
   * Returns a specific file from the given bucket
   * @param  {String} source The path to the remote file (bucket)
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  getFile: (source) ->
    @sendMetrics 'increment', 'file.get'
    @_knoxClient.getFileAsync source

  ###*
   * Uploads a given file to the given bucket, optionally showing the upload progress
   * @param  {String} source The path to the local file to upload
   * @param  {String} target The path to the remote destination file (bucket)
   * @param  {Object} header A JSON object containing some Headers to send
   * @param  {ProgressBar} [progressBar] An optional instance of {ProgressBar}
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  putFile: (source, target, header, progressBar) ->
    new Promise (resolve, reject) =>
      @sendMetrics 'increment', 'file.put'
      upload = @_knoxClient.putFile source, target, header, (err, resp) ->
        if err
          reject err
        else
          resolve resp
      upload.on 'progress', (d) ->
        progressBar?.update d.written / d.total,
          total: d.total
          percent: d.percent

  ###*
   * Uploads all files in the given directory to the given bucket, optionally showing the upload progress
   * @param  {String} source The path to the local directory to upload
   * @param  {String} target The path to the remote destination directory (bucket)
   * @param  {Object} header A JSON object containing some Headers to send
   * @param  {ProgressBar} [progressBar] An optional instance of {ProgressBar}
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  putDir: (source, target, header, progressBar) ->
    if fs.statSync(source).isDirectory()
      debug 'about to upload files in given directory %s', source
      fs.readdirAsync(source)
      .then (files) =>
        filesOnly = _.reject files, (file) -> fs.statSync("#{source}/#{file}").isDirectory()
        totFilesOnly = _.size(filesOnly)
        if totFilesOnly < _.size(files)
          debug 'found %s files (only) out of %s total, ignoring directories', totFilesOnly, _.size(files)
        progressBar?.total = totFilesOnly # override total of ProgressBar with correct value
        debug 'about to upload %s files', totFilesOnly
        Promise.map filesOnly, (file) =>
          @putFile "#{source}/#{file}", "#{target}/#{file}", header
          .then ->
            progressBar?.tick()
            Promise.resolve()
        , {concurrency: 5}
    else
      debug 'not a directory, uploading a single file'
      @putFile source, target, header, progressBar

  ###*
   * Copies a file directly in the bucket
   * @param  {String} source The path to the remote source file (bucket)
   * @param  {String} filename The path to the remote destination file (bucket)
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  copyFile: (source, destination) ->
    @sendMetrics 'increment', 'file.copy'
    @_knoxClient.copyFileAsync source, destination

  ###*
   * Moves a given file to the given bucket
   * @param  {String} source The path to the remote source file (bucket)
   * @param  {String} filename The path to the remote destination file (bucket)
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  moveFile: (source, destination) ->
    @copyFile(source, destination).then => @deleteFile source

  ###*
   * Deletes a file from the given bucket
   * @param  {String} file The path to the remote file to be deleted (bucket)
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  deleteFile: (file) ->
    @sendMetrics 'increment', 'file.delete'
    @_knoxClient.deleteFileAsync file

  ###*
   * @private
   *
   * Builds the correct key as image name
   * @param  {String} prefix A prefix for the image key
   * @param  {String} suffix A suffix for the image key
   * @param  {String} [extension] An optional file extension (default 'jpg')
   * @return {String} The built image key
  ###
  _imageKey: (prefix, suffix, extension) -> "#{prefix}#{suffix}#{extension or DEFAULT_IMG_EXTENSION}"

  ###*
   * @private
   *
   * Resizes and uploads a given image to the bucket
   * @param  {String} image The path the the image
   * @param  {String} prefix A prefix for the image key
   * @param  {Array} formats A list of formats for image resizing
   * @param  {String} [tmpDir] A path to a tmp folder
   * @return {Promise} A promise, fulfilled with the upload response or rejected with an error
  ###
  _resizeAndUploadImage: (image, prefix, formats, tmpDir = '/tmp') ->

    extension = path.extname image
    basename = path.basename image, extension
    basename_full = path.basename image
    tmp_original = "#{tmpDir}/#{basename_full}"

    Promise.map formats, (format) =>
      tmp_resized = @_imageKey "#{tmpDir}/#{basename}", format.suffix, extension

      debug 'about to resize image %s to %s', image, tmp_resized
      gm(tmp_original).resize format.height, format.width, ">"
      .write tmp_resized, (err) =>
        if err != undefined then Promise.reject(err)
        gm(tmp_resized).size (err, dimensions) =>
          if err != undefined then Promise.reject(err)
          @storeResizeDetails basename, format.suffix, dimensions
          @sendMetrics 'increment', 'image.resized'
          header =
            'x-amz-acl': 'public-read'
            'Cache-Control': 'max-age=31536000'
          aws_content_key = @_imageKey "#{prefix}#{basename}", format.suffix, extension
          debug 'about to upload resized image to %s', aws_content_key
          @putFile tmp_resized, aws_content_key, header
          Promise.resolve()
    , {concurrency: 1}

  ###*
   * Resizes and uploads a list of images to the bucket
   * Internally calls {@link _resizeAndUploadImage}
   * @param  {Array} images A list of images to be processed
   * @param  {Object} description A config JSON object describing the images conversion
   * @param  {String} [tmpDir] A path to a tmp folder
   * @return {Promise} A promise, fulfilled with a successful response or rejected with an error
  ###
  resizeAndUploadImages: (images, description, tmpDir = '/tmp') ->

    Promise.map images, (image) =>
      name = path.basename(image.Key)
      debug 'about to get image %s', name
      @sendMetrics 'increment', 'image.count'
      @getFile(image.Key)
      .then (response) ->
        tmp_resized = "#{tmpDir}/#{name}"
        stream = fs.createWriteStream tmp_resized
        new Promise (resolve, reject) ->
          response.pipe stream
          response.on 'end', resolve
          response.on 'error', reject
      .then => @_resizeAndUploadImage image.Key, description.prefix, description.formats, tmpDir
      .then (result) =>
        source = "#{description.prefix_unprocessed}/#{name}"
        target = "#{description.prefix_processed}/#{name}"
        debug "about to move file %s from '%s' to '%s'", name, source, target
        @moveFile source, target
      .then =>
        @emit 'progress'
        Promise.resolve()
    , {concurrency: 1}

module.exports = S3Client

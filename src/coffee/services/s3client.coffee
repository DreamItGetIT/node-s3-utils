debug = require('debug')('s3utils-s3client')
_ = require 'underscore'
colors = require 'colors'
path = require 'path'
knox = require 'knox'
Promise = require 'bluebird'
easyimage = require 'easyimage'
ProgressBar = require 'progress'
{CustomError} = require '../errors'
fs = Promise.promisifyAll require('fs')

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
    {key, secret, bucket} = opts
    throw new CustomError 'Missing AWS \'key\'' unless key
    throw new CustomError 'Missing AWS \'secret\'' unless secret
    throw new CustomError 'Missing AWS \'bucket\'' unless bucket

    @_knoxClient = knox.createClient
      key: key
      secret: secret
      bucket: bucket

    @_knoxClient = Promise.promisifyAll @_knoxClient

  ###*
   * Lists all files in the given bucket
   * @param  {Object} headers The headers to pass
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  list: (headers) -> @_knoxClient.listAsync headers

  ###*
   * Returns a specific file from the given bucket
   * @param  {String} source The path to the remote file (bucket)
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  getFile: (source) -> @_knoxClient.getFileAsync source

  ###*
   * Uploads a given file to the given bucket
   * @param  {String} source The path to the local file to upload
   * @param  {String} filename The path to the remote destination file (bucket)
   * @param  {Object} header A JSON object containing some Headers to send
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  putFile: (source, filename, header) -> @_knoxClient.putFileAsync source, filename, header

  ###*
   * Copies a file directly in the bucket
   * @param  {String} source The path to the remote source file (bucket)
   * @param  {String} filename The path to the remote destination file (bucket)
   * @return {Promise} A promise, fulfilled with the response or rejected with an error
  ###
  copyFile: (source, destination) -> @_knoxClient.copyFileAsync source, destination

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
  deleteFile: (file) -> @_knoxClient.deleteFileAsync file

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
    tmp_original = "/#{tmpDir}/#{basename_full}"

    Promise.map formats, (format) =>
      tmp_resized = @_imageKey "/#{tmpDir}/#{basename}", format.suffix, extension

      debug 'about to resize image %s to %s', image.Key, tmp_resized
      easyimage.resize
        src: tmp_original
        dst: tmp_resized
        width: format.width
        height: format.height
      .then (image) =>
        header = 'x-amz-acl': 'public-read'
        aws_content_key = @_imageKey "#{prefix}#{basename}", format.suffix, extension
        debug 'about to upload resized image to %s', aws_content_key
        @putFile tmp_resized, aws_content_key, header
      .catch (error) -> console.log error.message.red
    , {concurrency: 2}

  ###*
   * Resizes and uploads a list of images to the bucket
   * Internally calls {@link _resizeAndUploadImage}
   * @param  {Array} images A list of images to be processed
   * @param  {Object} description A config JSON object describing the images conversion
   * @param  {String} [tmpDir] A path to a tmp folder
   * @return {Promise} A promise, fulfilled with a successful response or rejected with an error
  ###
  resizeAndUploadImages: (images, description, tmpDir = '/tmp') ->

    bar = new ProgressBar "Processing prefix '#{description.prefix}':\t[:bar] :percent, :current of :total images done (time: elapsed :elapseds, eta :etas)",
      complete: '='
      incomplete: ' '
      width: 20
      total: images.length

    Promise.map images, (image) =>
      debug 'about to get image %s', image.Key
      @getFile(image.Key)
      .then (response) ->
        name = path.basename(image.Key)
        tmp_resized = "#{tmpDir}/#{name}"
        stream = fs.createWriteStream tmp_resized
        new Promise (resolve, reject) ->
          response.pipe stream
          response.on 'end', resolve
          response.on 'error', reject
      .then => @resizeAndUploadImage image.Key, description.prefix, description.formats, tmpDir
      .then (result) =>
        name = path.basename(image.Key)
        source = "#{description.prefix_unprocessed}#{name}"
        target = "#{description.prefix_processed}#{name}"
        @moveFile source, target
      .then -> Promise.resolve bar.tick()
    , {concurrency: 1}

module.exports = S3Client

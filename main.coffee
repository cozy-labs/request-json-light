FormData = require "form-data"
fs = require "fs"
url = require "url"
http = require 'http'
https = require 'https'
mime = require "mime"


# Merge two objects in one. Values from the second object win over the first
# one.
merge = (obj1, obj2) ->
    result = {}
    result[key] = obj1[key] for key of obj1
    if obj2?
        result[key] = obj2[key] for key of obj2
    result


# Build parameters required by http lib from options set on the client
# and extra options given for the request.
buildOptions = (clientOptions, clientHeaders, host, path, requestOptions) ->

    # Check if there is something to merge before performing additional
    # operation
    if requestOptions isnt {}
        options = merge clientOptions, requestOptions

    # Check if there are headers to merge before performing additional
    # operation on headers
    if requestOptions? and requestOptions isnt {} and requestOptions.headers
        options.headers = merge clientHeaders, requestOptions.headers

    # If no additional headers are given, it uses the client headers directly.
    else
        # we clone clientHeaders because playRequest mutate them
        # (delete content-type when there is no data)
        options.headers = merge clientHeaders, {}

    # Buuld host parameters from given URL.
    path = "/#{path}" if path[0] isnt '/'
    urlData = url.parse host
    options.host = urlData.host.split(':')[0]
    options.port = urlData.port
    options.protocol = urlData.protocol
    options.path = path
    if urlData.protocol is 'https:'
        options.requestFactory = https
        options.rejectUnauthorized = false
    else
        options.requestFactory = http

    options


# Parse body assuming the body is a json object. Send an error if the body
# can't be parsed.
parseBody =  (error, response, body, callback, parse=true) ->
    if typeof body is "string" and body isnt "" and parse
        try
            parsed = JSON.parse body
        catch err
            error ?= new Error("Parsing error: #{err.message}, body=\n#{body}")
            parsed = body

    else parsed = body

    callback error, response, parsed


# Generic command to play a simple request (withou streaming or form).
playRequest = (opts, data, callback, parse=true) ->

    if typeof data is 'function'
        callback = data
        data = {}

    if data?
        encoding = opts.encoding or 'utf8'
        # convert data to a buffer
        if typeof data is 'string'
            data = new Buffer data, encoding
        else unless data instanceof Buffer
            data = new Buffer(JSON.stringify(data), encoding)
        opts.headers['Content-Length'] = data.length

    else
        delete opts.headers['Content-Length']
        # remove the default 'application/json' header
        if opts.headers['content-type'] is 'application/json'
            delete opts.headers['content-type']

    req = opts.requestFactory.request opts, (res) ->
        res.setEncoding 'utf8'

        body = ''
        res.on 'data', (chunk) ->
            body += chunk
        res.on 'end', ->
            parseBody null, res, body, callback, parse

    req.on 'error', (err) ->
        err.message = """
          #{err.code} on #{opts.method} #{opts.protocol}://#{opts.host}#{opts.port}#{opts.path}
        """
        callback err

    req.write data if data?
    req.end()


# Function to make request json more modular.
module.exports =


    newClient: (url, options = {}) ->
        new JsonClient url, options


    get: (opts, data, callback, parse) ->
        opts.method = "GET"
        playRequest opts, data, callback, parse


    del: (opts, data, callback, parse) ->
        opts.method = "DELETE"
        playRequest opts, data, callback, parse


    post: (opts, data, callback, parse) ->
        opts.method = "POST"
        playRequest opts, data, callback, parse


    put: (opts, data, callback, parse) ->
        opts.method = "PUT"
        playRequest opts, data, callback, parse


    patch: (opts, data, callback, parse) ->
        opts.method = "PATCH"
        playRequest opts, data, callback, parse


    head: (opts, data, callback) ->
        opts.method = "HEAD"
        playRequest opts, data, callback


# Small HTTP client for easy json interactions with Cozy backends.
class JsonClient


    # Set default headers
    constructor: (@host, @options = {}) ->
        @headers = @options.headers ? {}
        @headers['accept'] = 'application/json'
        @headers['user-agent'] = "request-json/1.0"
        @headers['content-type'] = 'application/json'

    # Set basic authentication on each requests
    setBasicAuth: (username, password) ->
        credentials = "#{username}:#{password}"
        basicCredentials = new Buffer(credentials).toString('base64')
        @headers["authorization"] = "Basic #{basicCredentials}"


    # Add a token to request header.
    setToken: (token) ->
        @headers["x-auth-token"] = token


    # Send a GET request to path. Parse response body to obtain a JS object.
    get: (path, options, callback, parse=true) ->
        if typeof options is 'function'
            parse = callback if typeof callback is 'boolean'
            callback = options
            options = {}

        opts = buildOptions @options, @headers, @host, path, options
        module.exports.get opts, null, callback, parse


    # Send a POST request to path with given JSON as body.
    post: (path, data, options, callback, parse=true) ->
        if typeof options is 'function'
            parse = callback if typeof callback is 'boolean'
            callback = options
            options = {}

        if typeof data is 'function'
            parse = options if typeof options is 'boolean'
            callback = data
            data = {}
            options = {}

        opts = buildOptions @options, @headers, @host, path, options
        module.exports.post opts, data, callback


    # Send a PUT request to path with given JSON as body.
    put: (path, data, options, callback, parse=true) ->
        if typeof options is 'function'
            parse = callback if typeof callback is 'boolean'
            callback = options
            options = {}

        opts = buildOptions @options, @headers, @host, path, options
        module.exports.put opts, data, callback, parse


    # Send a PATCH request to path with given JSON as body.
    patch: (path, data, options, callback, parse=true) ->
        if typeof options is 'function'
            parse = callback if typeof callback is 'boolean'
            callback = options
            options = {}

        opts = buildOptions @options, @headers, @host, path, options
        module.exports.patch opts, data, callback, parse


    # Send a DELETE request to path.
    del: (path, options, callback, parse=true) ->
        if typeof options is 'function'
            parse = callback if typeof callback is 'boolean'
            callback = options
            options = {}

        opts = buildOptions @options, @headers, @host, path, options
        module.exports.del opts, null, callback, parse


    # Alias for del function
    delete: (path, options, callback, parse=true) ->
        @del path, options, callback, parse


    # Send a HEAD request to path with given JSON as body.
    head: (path, data, options, callback, parse = true) ->
        if typeof options is 'function'
            parse = callback if typeof callback is 'boolean'
            callback = options
            options = {}

        opts = buildOptions @options, @headers, @host, path, options
        module.exports.head opts, null, callback


    # Send a post request with file located at given path as attachment
    # (multipart form)
    sendFile: (path, files, data, callback, parse=true) ->
        callback = data if typeof(data) is "function"

        form = new FormData()

        # Append fields to form.
        unless typeof(data) is "function"
            for att of data
                form.append att, data[att]

        # files is a string so it is a file path
        if typeof files is "string"
            form.append "file", fs.createReadStream files

        # files is not a string and is not an array so it is a stream
        else if not Array.isArray files
            # A path is required by formData
            files.path = files.path or "useless_But_Required_String"
            form.append "file", files

        # files is an array of strings and streams
        else
            index = 0
            for file in files
                index++
                if typeof file is "string"
                    form.append "file#{index}", fs.createReadStream(file)
                else
                    form.append "file#{index}", file

        # build form data options from @options
        options = buildOptions @options, @headers, @host, path, method: 'POST'

        # the form will have a multipart content-type, formdata handles it
        delete options.headers['content-type']

        # formdata expects a 'https:' options protocol
        if options.requestFactory is https
            options.protocol = 'https:'
        delete options.requestFactory

        form.submit options, (err, res) ->
            return callback err if err

            res.setEncoding 'utf8'

            body = ''

            res.on 'data', (chunk) ->
                body += chunk

            res.on 'end', ->
                parseBody null, res, body, callback, parse


    # Send a put request with file located at given path as body.
    # Do not use form, file is sent directly
    putFile: (path, file, callback, parse=true) ->
        opts = buildOptions @options, @headers, @host, path, method: 'PUT'

        # file is a string so it is a file path
        if typeof file is "string"
            opts.headers['content-type'] = mime.lookup file
            fileStream = fs.createReadStream(file)

        # file is not a string so it should be a stream.
        else
            fileStream = file

        req = opts.requestFactory.request opts, (res) ->
            res.setEncoding 'utf8'

            body = ''
            res.on 'data', (chunk) -> body += chunk
            res.on 'end', ->
                parseBody null, res, body, callback, parse

        req.on 'error', (err) ->
            callback err

        reqStream = fileStream.pipe req
        {reqStream, fileStream}



    # Retrieve file located at *path* and save it as *filePath*.
    # Use a write stream for that.
    saveFile: (path, filePath, callback) ->
        options = {}
        opts = buildOptions @options, @headers, @host, path, options
        opts.option = "GET"

        req = opts.requestFactory.request opts, (res) ->
            fileStream = fs.createWriteStream filePath
            res.pipe fileStream
            fileStream.on 'finish', ->
                callback null, res

        req.on 'error', (err)  ->
            callback err

        req.end()


    # Retrieve file located at *path* and return it as stream.
    saveFileAsStream: (path, callback) ->
        options = {}
        opts = buildOptions @options, @headers, @host, path, options
        opts.option = "GET"

        req =  opts.requestFactory.request opts, (res) ->
            callback null, res

        req.on 'error', (err)  ->
            callback err

        req.end()

module.exports.JsonClient = JsonClient

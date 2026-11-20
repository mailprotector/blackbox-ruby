require 'uri'
module Blackbox
  module Scrubber
    FILTERED = '[FILTERED]'
    module_function
    def text(value, limit = 4000)
      string = value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').gsub('\\/', '/')
      4.times do
        break unless string.match?(/%[0-9a-f]{2}/i)
        string = URI::DEFAULT_PARSER.unescape(string).force_encoding('UTF-8')
        return FILTERED unless string.valid_encoding?
      end
      return FILTERED if string.match?(/%[0-9a-f]{2}/i)
      string.gsub('\\/', '/')
        .gsub(%r{(/xray/shares/)[^\s/?#"'<>]+}i, '\1[FILTERED]')
        .gsub(%r{(https?://)[^\s/@]+@}i, '\1[FILTERED]@')
        .gsub(/[?#][^\s"'<>]*/, FILTERED)
        .gsub(/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=\-]+/i, '\1 [FILTERED]')
        .gsub(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/, FILTERED)
        .gsub(/["']?\b(password|passwd|secret|token|api[_-]?key|authorization|cookie)\b["']?\s*[=:]\s*(?:\[FILTERED\]|"[^"]*"|'[^']*'|[^\s,;]+)/i, '\1=[FILTERED]')
        .gsub(/[A-Z0-9.!#$%&'*+\/= ?^_`{|}~\-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)+/i, FILTERED)
        .gsub(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/, ' ')[0, limit]
    end
    def context(input)
      result = {}
      result['component'] = text(input[:component] || input['component'], 200) if input[:component] || input['component']
      request = input[:request] || input['request']
      if request.is_a?(Hash)
        method = (request[:method] || request['method']).to_s.upcase
        if %w[GET HEAD POST PUT PATCH DELETE OPTIONS].include?(method)
          result['request'] = { 'method' => method, 'path' => text(request[:path] || request['path'] || '/', 1000) }
          %w[controller action].each { |key| result['request'][key] = text(request[key] || request[key.to_sym], 100) if request[key] || request[key.to_sym] }
        end
      end
      job = input[:job] || input['job']
      if job.is_a?(Hash) && (job[:class] || job['class'])
        result['job'] = { 'class' => text(job[:class] || job['class'], 200) }
        result['job']['queue'] = text(job[:queue] || job['queue'], 100) if job[:queue] || job['queue']
      end
      result
    end
  end
end

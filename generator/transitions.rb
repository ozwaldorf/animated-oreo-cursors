#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'open3'
require 'optparse'
require 'rexml/document'
require 'tmpdir'

module Transitions
  ROOT = File.expand_path('..', __dir__)
  THEME = 'oreo_spark_black_bordered_cursors'
  SHAPES = {
    'default' => 'default', 'pointer' => 'pointer', 'text' => 'text',
    'ew-resize' => 'size_hor', 'ns-resize' => 'size_ver',
    'nesw-resize' => 'size_bdiag', 'nwse-resize' => 'size_fdiag',
    'col-resize' => 'col-resize', 'grab' => 'openhand', 'grabbing' => 'dnd-move',
    'progress' => 'progress-01', 'wait' => 'wait-01', 'copy' => 'copy',
    'not-allowed' => 'not-allowed', 'no-drop' => 'no-drop',
    'crosshair' => 'crosshair', 'vertical-text' => 'vertical-text',
    'zoom-in' => 'zoom-in', 'zoom-out' => 'zoom-out'
  }.freeze
  TOP_ANCHORED = (SHAPES.keys - %w[default pointer progress copy no-drop]).freeze
  ALIASES = {
    'ew-resize' => %w[e-resize w-resize],
    'ns-resize' => %w[n-resize s-resize row-resize],
    'nesw-resize' => %w[ne-resize sw-resize],
    'nwse-resize' => %w[nw-resize se-resize],
    'grabbing' => %w[move all-resize]
  }.freeze
  PAIRS = [
    %w[default pointer], %w[default text], %w[pointer text],
    %w[default ew-resize], %w[default ns-resize],
    %w[default nesw-resize], %w[default nwse-resize], %w[default col-resize],
    %w[default grab], %w[grab grabbing], %w[default grabbing],
    %w[default progress], %w[default wait],
    %w[grabbing copy], %w[grabbing not-allowed], %w[grabbing no-drop],
    %w[default crosshair], %w[text vertical-text], %w[zoom-in zoom-out]
  ].freeze
  SIZES = [24, 32, 40, 48, 56, 64].freeze
  SCALE = 4
  FRAMES = 24
  DELAY = 5

  def self.run(*args, input: '')
    environment = {
      'DBUS_SESSION_BUS_ADDRESS' => nil, 'DISPLAY' => nil, 'WAYLAND_DISPLAY' => nil,
      'XDG_RUNTIME_DIR' => nil, 'GTK_USE_PORTAL' => '0', 'GIO_USE_VFS' => 'local'
    }
    output, error, status = Open3.capture3(environment, *args, stdin_data: input, binmode: true)
    raise "#{args.first} failed: #{error}" unless status.success?

    output
  end

  def self.render(source, output, size)
    run('inkscape', source, "--export-filename=#{output}",
        "--export-width=#{size}", "--export-height=#{size}")
    run('magick', output, '-depth', '8', 'rgba:-').unpack('C*')
  end

  def self.hotspot(shape, size)
    File.foreach(File.join(ROOT, 'src', 'config', "#{shape}.cursor")) do |line|
      fields = line.split
      return fields[1, 2].map(&:to_i) if fields[0].to_i == size
    end
    raise "No hotspot for #{shape} at #{size}"
  end

  POINTS = 256

  def self.anchor_theme(directory)
    directory = File.realpath(directory)
    files = Dir.children(directory).map { |name| File.join(directory, name) }
    groups = files.reject { |path| File.symlink?(path) || !File.file?(path) }.group_by { |path| Digest::SHA256.file(path).hexdigest }
    copies = groups.values.flat_map { |paths| paths.map { |path| [path, paths] } }.to_h
    hotspots = {}
    SHAPES.each_key do |shape|
      path = File.realpath(File.join(directory, shape))
      raise "Cursor outside output theme: #{shape}" unless path.start_with?(File.realpath(directory) + '/')

      data = File.binread(path)
      magic, header, _, count = data.unpack('V4')
      raise "Invalid Xcursor: #{shape}" unless magic == 0x72756358

      frames = count.times.filter_map do |index|
        kind, size, offset = data.byteslice(header + index * 12, 12).unpack('V3')
        [size, offset] if kind == 0xfffd0002
      end
      frames.group_by(&:first).each do |size, entries|
        xhot, yhot = data.byteslice(entries.first[1] + 24, 8).unpack('V2')
        if TOP_ANCHORED.include?(shape)
          yhot = entries.map do |_, offset|
            chunk_header, _, _, _, width, height = data.byteslice(offset, 24).unpack('V6')
            pixels = data.byteslice(offset + chunk_header, width * height * 4).unpack('V*')
            first = pixels.index { |pixel| pixel >> 24 >= 128 }
            raise "Empty cursor: #{shape}" unless first

            first / width
          end.min
          entries.each { |_, offset| data[offset + 28, 4] = [yhot].pack('V') }
        end
        hotspots[[shape, size]] = [xhot, yhot]
      end
      copies.fetch(path).each { |copy| File.binwrite(copy, data) } if TOP_ANCHORED.include?(shape)
    end
    hotspots
  end

  def self.resample(contour, count = POINTS)
    edges = contour.zip(contour.rotate).map { |a, b| Math.hypot(b[0] - a[0], b[1] - a[1]) }
    perimeter = edges.sum
    raise 'Empty contour' unless perimeter.positive?

    edge = 0
    traversed = 0.0
    Array.new(count) do |index|
      position = index * perimeter / count
      while edge < edges.length - 1 && traversed + edges[edge] <= position
        traversed += edges[edge]
        edge += 1
      end
      t = (position - traversed) / edges[edge]
      contour[edge].zip(contour[(edge + 1) % contour.length]).map { |a, b| a + (b - a) * t }
    end
  end

  def self.trace_contours(occupied)
    mask = occupied.to_h { |point| [point, true] }
    edges = Hash.new { |hash, key| hash[key] = [] }
    occupied.each do |x, y|
      edges[[x, y]] << [x + 1, y] unless mask[[x, y - 1]]
      edges[[x + 1, y]] << [x + 1, y + 1] unless mask[[x + 1, y]]
      edges[[x + 1, y + 1]] << [x, y + 1] unless mask[[x, y + 1]]
      edges[[x, y + 1]] << [x, y] unless mask[[x - 1, y]]
    end
    contours = []
    until edges.empty?
      first = edges.keys.first
      point = first
      contour = []
      loop do
        contour << point
        following = edges.fetch(point).shift
        edges.delete(point) if edges[point].empty?
        point = following
        break if point == first
      end
      contours << contour
    end
    contours.select { |contour| area(contour).abs > 4 }.sort_by { |contour| -area(contour).abs }.map { |contour| resample(contour) }
  end

  def self.area(contour)
    contour.zip(contour.rotate).sum { |a, b| a[0] * b[1] - b[0] * a[1] } / 2.0
  end

  def self.trace_contour(occupied)
    trace_contours(occupied).first
  end

  def self.normalized(contour)
    center = [0, 1].map { |axis| contour.sum { |point| point[axis] }.fdiv(contour.length) }
    centered = contour.map { |point| point.zip(center).map { |a, b| a - b } }
    radius = Math.sqrt(centered.sum { |x, y| x * x + y * y } / contour.length)
    centered.map { |x, y| [x / radius, y / radius] }
  end

  # Keep winding and point order; only rotate the starting index.
  def self.align_contours(source, target)
    a, b = [normalized(source), normalized(target)]
    offset = target.length.times.min_by do |shift|
      a.each_index.sum do |index|
        x, y = b[(index + shift) % b.length]
        (a[index][0] - x)**2 + (a[index][1] - y)**2
      end
    end
    target.rotate(offset)
  end

  def self.interpolate(source, target, progress)
    t = progress * progress * (3 - 2 * progress)
    source.zip(target).map { |a, b| a.zip(b).map { |x, y| x + (y - x) * t } }
  end

  def self.property(node, name)
    style = node.attributes['style'].to_s.split(';').filter_map do |item|
      key, value = item.split(':', 2)
      [key.strip, value.strip] if value
    end.to_h
    (style[name] || node.attributes[name]).to_s.downcase
  end

  def self.bounds(contours)
    points = contours.flatten(1)
    xs, ys = points.transpose
    [(xs.min + xs.max) / 2, (ys.min + ys.max) / 2, xs.max - xs.min, ys.max - ys.min]
  end

  def self.prepare(shape, size, work, hotspots)
    width = size * SCALE * 2
    artwork = SHAPES.fetch(shape)
    source = File.join(ROOT, 'src', THEME, "#{artwork}.svg")
    pixels = render(source, File.join(work, "#{shape}.png"), size * SCALE)
    document = REXML::Document.new(File.read(source))
    foreground = document.root.elements.to_a.select do |node|
      %w[path circle ellipse rect polygon g].include?(node.name) && property(node, 'filter').empty?
    end
    main = foreground.find { |node| property(node, 'stroke') == '#ffffff' }
    raise "Missing bordered body in #{source}" unless main

    color = property(main, 'fill')
    bodies = foreground.select { |node| property(node, 'fill') == color }
    details = foreground - bodies
    detail_document = REXML::Document.new(File.read(source))
    detail_document.root.elements.to_a.each do |node|
      next if node.name == 'defs' || details.any? { |detail| detail.attributes['id'] == node.attributes['id'] }
      detail_document.root.delete_element(node)
    end
    document.root.elements.to_a.each { |node| document.root.delete_element(node) unless bodies.include?(node) }
    bodies.each { |node| node.add_attributes('fill' => '#ffffff', 'opacity' => '1', 'style' => 'stroke:none') }
    mask_source = File.join(work, "#{shape}-mask.svg")
    File.write(mask_source, document.to_s)
    mask_pixels = render(mask_source, File.join(work, "#{shape}-mask.png"), size * SCALE)
    xhot, yhot = hotspots.fetch([shape, size])
    offset_x, offset_y = [(size - xhot) * SCALE, (size - yhot) * SCALE]
    endpoint = Array.new(width * width * 4, 0)
    occupied = []
    (size * SCALE).times do |y|
      (size * SCALE).times do |x|
        source_index = (y * size * SCALE + x) * 4
        destination = ((y + offset_y) * width + x + offset_x) * 4
        endpoint[destination, 4] = pixels[source_index, 4]
        occupied << [x + offset_x, y + offset_y] if mask_pixels[source_index + 3] > 127
      end
    end
    raise "Empty silhouette in #{source}" if occupied.empty?

    detail_path = nil
    unless details.empty?
      detail_source = File.join(work, "#{shape}-details.svg")
      File.write(detail_source, detail_document.to_s)
      detail_path = File.join(work, "#{shape}-details.png")
      render(detail_source, detail_path, size * SCALE)
      run('magick', '-size', "#{width}x#{width}", 'xc:none', detail_path,
          '-geometry', "+#{offset_x}+#{offset_y}", '-compose', 'over', '-composite', detail_path)
    end
    contours = trace_contours(occupied)
    { endpoint: endpoint, contours: contours, color: color, details: detail_path, bounds: bounds(contours) }
  end

  def self.match_contours(source, target)
    remaining = target.map(&:dup)
    matches = source.map do |contour|
      candidates = remaining.select { |other| area(contour).positive? == area(other).positive? }
      other = candidates.min_by do |candidate|
        a, b = [bounds([contour]), bounds([candidate])]
        Math.hypot(a[0] - b[0], a[1] - b[1]) + (Math.sqrt(area(contour).abs) - Math.sqrt(area(candidate).abs)).abs
      end
      if other
        remaining.delete(other)
        [contour, align_contours(contour, other)]
      else
        center = bounds([contour])[0, 2]
        [contour, Array.new(POINTS) { center }]
      end
    end
    matches + remaining.map do |contour|
      center = bounds([contour])[0, 2]
      [Array.new(POINTS) { center }, contour]
    end
  end

  def self.path_data(points)
    midpoints = points.zip(points.rotate).map { |a, b| a.zip(b).map { |x, y| (x + y) / 2 } }
    "M #{midpoints.last.join(' ')} " + points.each_index.map do |i|
      "Q #{points[i].join(' ')} #{midpoints[i].join(' ')}"
    end.join(' ') + ' Z'
  end

  def self.detail_layer(shape, box, opacity, width)
    return '' unless shape[:details] && opacity.positive?

    x, y, w, h = shape[:bounds]
    cx, cy, cw, ch = box
    %(<g opacity="#{opacity}" transform="translate(#{cx} #{cy}) scale(#{cw / w} #{ch / h}) translate(#{-x} #{-y})"><image href="#{shape[:details]}" width="#{width}" height="#{width}"/></g>)
  end

  def self.frame(a, b, matches, index, size, output, work)
    width = size * SCALE * 2
    if index.zero? || index == FRAMES - 1
      pixels = index.zero? ? a[:endpoint] : b[:endpoint]
      run('magick', '-size', "#{width}x#{width}", '-depth', '8', 'rgba:-',
          '-filter', 'Lanczos', '-resize', "#{size * 2}x#{size * 2}", output, input: pixels.pack('C*'))
      return
    end
    progress = index.fdiv(FRAMES - 1)
    t = progress * progress * (3 - 2 * progress)
    paths = matches.map do |first, last|
      opacity = first.uniq.length == 1 ? t : (last.uniq.length == 1 ? 1 - t : 1)
      [path_data(interpolate(first, last, progress)), opacity]
    end
    color = a[:color].delete_prefix('#').scan(/../).zip(b[:color].delete_prefix('#').scan(/../)).map do |first, last|
      (first.to_i(16) * (1 - t) + last.to_i(16) * t).round
    end
    box = a[:bounds].zip(b[:bounds]).map { |first, last| first * (1 - t) + last * t }
    source = File.join(work, 'contour.svg')
    File.write(source, <<~SVG)
      <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{width}" viewBox="0 0 #{width} #{width}">
        <path d="#{paths.map(&:first).join(' ')}" fill="rgb(#{color.join(',')})" fill-rule="evenodd"/>
        <g fill="none" stroke="white" stroke-width="#{size.fdiv(32) * SCALE}" stroke-linejoin="round">
          #{paths.map { |path, opacity| %(<path d="#{path}" opacity="#{opacity}"/>) }.join}
        </g>
        #{detail_layer(a, box, 1 - t, width)}
        #{detail_layer(b, box, t, width)}
      </svg>
    SVG
    body = File.join(work, 'body.png')
    run('inkscape', source, "--export-filename=#{body}")
    run('magick', '(', body, '-channel', 'A', '-blur', "0x#{size.fdiv(32) * 0.7 * SCALE}",
        '-evaluate', 'multiply', '0.3', '+channel', '-fill', 'black', '-colorize', '100',
        '-roll', "+0+#{(size.fdiv(32) * 1.5 * SCALE).round}", ')', body,
        '-compose', 'over', '-composite', '-filter', 'Lanczos',
        '-resize', "#{size * 2}x#{size * 2}", output)
  end

  def self.preview_frames(frames, name, preview)
    FileUtils.mkdir_p(preview)
    run('magick', *frames, '-background', '#555555', '-alpha', 'remove',
        '+append', File.join(preview, "#{name}.png"))
    sequence = [frames.first] * 20 + frames + [frames.last] * 20 + frames.reverse
    run('magick', '-delay', '2', *sequence, '-background', '#555555',
        '-alpha', 'remove', '-filter', 'point', '-resize', '384x384',
        '-loop', '0', File.join(preview, "#{name}.gif"))
  end

  def self.transition_names(pair)
    ([pair[0]] + ALIASES.fetch(pair[0], [])).product([pair[1]] + ALIASES.fetch(pair[1], [])).map do |from, to|
      "#{from}-to-#{to}"
    end
  end

  def self.generate(output, preview = nil)
    FileUtils.mkdir_p(output)
    hotspots = anchor_theme(output)
    Dir.mktmpdir('oreo-transitions-') do |work|
      configs = PAIRS.to_h { |pair| [pair, []] }
      SIZES.each do |size|
        shapes = SHAPES.keys.to_h { |shape| [shape, prepare(shape, size, work, hotspots)] }
        queue = Queue.new
        configs.each { |pair, lines| queue << [pair, lines] }
        workers = Array.new([4, configs.length].min) do
          Thread.new do
            loop do
              begin
                pair, lines = queue.pop(true)
              rescue ThreadError
                break
              end
              name = pair.join('-to-')
              pair_work = File.join(work, name)
              FileUtils.mkdir_p(pair_work)
              matches = match_contours(shapes[pair[0]][:contours], shapes[pair[1]][:contours])
              frames = Array.new(FRAMES) do |index|
                filename = "#{name}-#{size}-#{index}.png"
                frame(shapes[pair[0]], shapes[pair[1]], matches, index, size, File.join(work, filename), pair_work)
                lines << "#{size} #{size} #{size} #{filename} #{DELAY}"
                File.join(work, filename)
              end
              preview_frames(frames, name, preview) if preview && size == SIZES.last
            end
          end
        end
        workers.each(&:value)
      end
      configs.each do |pair, lines|
        name = pair.join('-to-')
        config = File.join(work, "#{name}.cursor")
        File.write(config, lines.join("\n") + "\n")
        run('xcursorgen', '-p', work, config, File.join(output, name))
        transition_names(pair).each do |alias_name|
          File.symlink(name, File.join(output, alias_name)) unless alias_name == name
        end
      end
    end
  end

  def self.main
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: transitions.rb --base-theme PATH --output PATH [--preview PATH]'
      opts.on('--base-theme PATH') { |value| options[:base] = value }
      opts.on('--output PATH') { |value| options[:output] = value }
      opts.on('--preview PATH') { |value| options[:preview] = value }
    end
    parser.parse!
    abort parser.to_s unless options[:base] && options[:output]
    abort 'Output already exists; choose a fresh directory' if File.exist?(options[:output])
    FileUtils.mkdir_p(File.dirname(options[:output]))
    FileUtils.cp_r(options[:base], options[:output], dereference_root: true)
    Dir.glob(File.join(options[:output], '**', '*')).each do |path|
      File.chmod(File.directory?(path) ? 0o755 : 0o644, path) unless File.symlink?(path)
    end
    File.chmod(0o755, options[:output])
    File.write(File.join(options[:output], 'index.theme'),
               "[Icon Theme]\nName=Animated Oreo Spark Black Bordered\nComment=Oreo with reversible cursor transitions\n")
    generate(File.join(options[:output], 'cursors'), options[:preview])
  end
end

Transitions.main if $PROGRAM_NAME == __FILE__

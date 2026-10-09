# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../generator/transitions'

class TransitionFilesTest < Minitest::Test
  CURSORS = ENV.fetch('CURSOR_DIRECTORY', 'build/animated_oreo_spark_black_bordered_cursors/cursors')

  def images(name)
    data = File.binread(File.join(CURSORS, name))
    _, header, _, count = data.unpack('V4')
    count.times.map do |index|
      _, size, offset = data.byteslice(header + index * 12, 12).unpack('V3')
      chunk, _, _, _, width, height, xhot, yhot = data.byteslice(offset, 32).unpack('V8')
      pixels = data.byteslice(offset + chunk, width * height * 4).unpack('V*')
      { size: size, width: width, xhot: xhot, yhot: yhot, pixels: pixels }
    end
  end

  def visible_bounds(image)
    points = image[:pixels].each_index.filter_map do |index|
      [index % image[:width] - image[:xhot], index / image[:width] - image[:yhot]] if image[:pixels][index] >> 24 >= 128
    end
    xs, ys = points.transpose
    [xs.min, ys.min, xs.max, ys.max]
  end

  def test_centered_cursors_are_top_anchored_and_pointed_cursors_keep_hotspots
    Transitions::SHAPES.each do |shape, artwork|
      images(shape).group_by { |image| image[:size] }.each do |size, frames|
        original = Transitions.hotspot(artwork.sub(/-\d+$/, ''), size)
        assert frames.all? { |image| image[:xhot] == original[0] }, shape
        if Transitions::TOP_ANCHORED.include?(shape)
          assert_equal 1, frames.map { |image| image[:yhot] }.uniq.length, shape
          assert_equal 0, frames.map { |image| visible_bounds(image)[1] }.min, shape
          assert_operator frames.first[:yhot], :<, original[1], shape
        else
          assert frames.all? { |image| image[:yhot] == original[1] }, shape
        end
      end
    end
    { 'xterm' => 'text', 'row-resize' => 'ns-resize', 'move' => 'grabbing' }.each do |name, canonical|
      assert_equal Digest::SHA256.file(File.join(CURSORS, canonical)).hexdigest,
                   Digest::SHA256.file(File.join(CURSORS, name)).hexdigest, name
    end
  end

  def test_transition_endpoints_align_with_ordinary_cursors
    Transitions::PAIRS.each do |pair|
      normal = pair.map { |name| images(name).group_by { |image| image[:size] } }
      images(pair.join('-to-')).group_by { |image| image[:size] }.each do |size, frames|
        [frames.first, frames.last].each_with_index do |endpoint, index|
          visible_bounds(endpoint).zip(visible_bounds(normal[index].fetch(size).first)).each do |actual, expected|
            assert_in_delta expected, actual, 1, "#{pair[index]} at #{size}"
          end
        end
      end
    end
  end

  def test_frames_sizes_hotspots_and_timing
    cursors = CURSORS
    Transitions::PAIRS.map { |pair| pair.join('-to-') }.each do |name|
      data = File.binread(File.join(cursors, name))
      magic, header, version, count = data.unpack('V4')
      assert_equal 0x72756358, magic
      assert_equal 0x10000, version
      assert_equal 144, count
      sizes = Hash.new(0)
      count.times do |index|
        kind, size, offset = data.byteslice(header + index * 12, 12).unpack('V3')
        assert_equal 0xfffd0002, kind
        chunk_header, _, subtype, _, width, height, xhot, yhot, delay = data.byteslice(offset, 36).unpack('V9')
        assert_equal size, subtype
        assert_equal [2 * size, 2 * size, size, size], [width, height, xhot, yhot]
        assert_equal 5, delay
        assert_operator offset + chunk_header + width * height * 4, :<=, data.bytesize
        assert data.byteslice(offset + chunk_header, width * height * 4).unpack('V*').any? { |pixel| pixel >> 24 > 0 }
        sizes[size] += 1
      end
      assert_equal [24, 32, 40, 48, 56, 64].to_h { |size| [size, 24] }, sizes
    end
    %w[default pointer text left_ptr xterm].each { |shape| assert File.file?(File.join(cursors, shape)) }
  end

  def test_aliases_share_transition_files
    cursors = CURSORS
    assert_equal 19, Transitions::PAIRS.length
    Transitions::PAIRS.each do |pair|
      canonical = File.join(cursors, pair.join('-to-'))
      Transitions.transition_names(pair).drop(1).each do |name|
        path = File.join(cursors, name)
        assert File.symlink?(path), name
        assert_equal File.realpath(canonical), File.realpath(path)
      end
    end
  end

  def test_contours_preserve_holes_and_disconnected_parts
    occupied = (0...12).flat_map do |y|
      (0...12).filter_map { |x| [x, y] unless x.between?(4, 7) && y.between?(4, 7) }
    end
    occupied += (20...25).flat_map { |y| (20...25).map { |x| [x, y] } }
    contours = Transitions.trace_contours(occupied)
    assert_equal 3, contours.length
    assert_equal 1, contours.count { |contour| Transitions.area(contour).negative? }
    matches = Transitions.match_contours([contours.first], contours)
    assert_equal 3, matches.length
    matches.drop(1).each { |source, _| assert_equal 1, source.uniq.length }
  end

  def test_resampling_preserves_square_perimeter
    points = Transitions.resample([[0, 0], [4, 0], [4, 4], [0, 4]], 16)
    assert_equal 16, points.length
    points.zip(points.rotate).each do |a, b|
      assert_in_delta 1, Math.hypot(a[0] - b[0], a[1] - b[1]), 1e-10
    end
  end

  def test_correspondence_handles_rotated_start_and_translated_scaled_shape
    source = Transitions.resample([[0, 0], [4, 0], [3, 5], [0, 3]], 32)
    target = source.map { |x, y| [x * 2 + 10, y * 2 - 7] }.rotate(11)
    aligned = Transitions.align_contours(source, target)
    source.zip(aligned).each do |a, b|
      assert_in_delta a[0] * 2 + 10, b[0], 1e-10
      assert_in_delta a[1] * 2 - 7, b[1], 1e-10
    end
    assert_equal source, Transitions.interpolate(source, aligned, 0)
    Transitions.interpolate(source, aligned, 1).zip(aligned).each do |actual, expected|
      actual.zip(expected).each { |x, y| assert_in_delta y, x, 1e-10 }
    end
  end

  def test_contour_tracing_ignores_disconnected_speck
    occupied = (0...5).flat_map { |y| (0...7).map { |x| [x, y] } } + [[20, 20]]
    contour = Transitions.trace_contour(occupied)
    assert_equal 256, contour.length
    assert contour.all? { |x, y| x.between?(0, 7) && y.between?(0, 5) }
  end
end

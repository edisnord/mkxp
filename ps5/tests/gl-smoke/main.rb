# Renders a few sprites through mkxp's shaders, reads the frame back and
# writes pixel samples to result.txt (compared against expected.txt).
begin
  results = []
  bg = Sprite.new
  bg.bitmap = Bitmap.new(640, 480)
  bg.bitmap.fill_rect(0, 0, 640, 480, Color.new(0, 0, 255))
  red = Sprite.new
  red.bitmap = Bitmap.new(100, 100)
  red.bitmap.fill_rect(0, 0, 100, 100, Color.new(255, 0, 0))
  red.x = 50; red.y = 50; red.z = 10
  toned = Sprite.new
  toned.bitmap = Bitmap.new(100, 100)
  toned.bitmap.fill_rect(0, 0, 100, 100, Color.new(128, 128, 128))
  toned.x = 200; toned.y = 50; toned.z = 10
  toned.tone = Tone.new(0, 0, 0, 255)            # sprite shader: grayscale
  toned.color = Color.new(0, 255, 0, 255)        # sprite shader: flash color
  text = Sprite.new
  text.bitmap = Bitmap.new(300, 60)
  text.bitmap.font.size = 40
  text.bitmap.draw_text(0, 0, 300, 60, "Core profile")
  text.x = 50; text.y = 300; text.z = 10
  hue = Sprite.new
  hue.bitmap = Bitmap.new(100, 100)
  hue.bitmap.fill_rect(0, 0, 100, 100, Color.new(255, 0, 0))
  hue.bitmap.hue_change(120)                      # hue shader
  hue.x = 350; hue.y = 50; hue.z = 10
  Graphics.freeze
  Graphics.transition(10)                         # transition shader
  20.times { Graphics.update }
  snap = Graphics.snap_to_bitmap
  [[10, 10, "bg"], [100, 100, "red"], [250, 100, "toned"], [400, 100, "hue"]].each do |x, y, n|
    c = snap.get_pixel(x, y)
    results << "#{n} #{c.red.to_i} #{c.green.to_i} #{c.blue.to_i}"
  end
  # count non-background pixels in the text area
  lit = 0
  (300...360).step(2) { |y| (50...350).step(2) { |x| c = snap.get_pixel(x, y); lit += 1 if c.red > 128 && c.green > 128 } }
  results << "text_pixels #{lit}"
rescue Exception => e
  results << "ERROR #{e.class}: #{e.message} #{e.backtrace.inspect}"
end
File.open("result.txt", "w") { |f| f.puts results }
exit

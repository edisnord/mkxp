//=============================================================================
// MkxpSmoke.js
//=============================================================================

/*:
 * @plugindesc Test scene for mkxp's PS5 MV/MZ runtime check.
 *
 * @help Replaces the boot scene with a scene that draws a blue background,
 * a red square and some text, writes pixel samples of the bitmaps to
 * result.txt in the game folder after one second, and quits after four
 * (time for a screenshot of what reached the screen).
 */

(function() {
    'use strict';

    var fs = require('fs');
    var path = require('path');

    // No database or system pictures: go straight to the test scene
    Scene_Boot.prototype.create = function() {
        Scene_Base.prototype.create.call(this);
    };

    Scene_Boot.prototype.isReady = function() {
        return Scene_Base.prototype.isReady.call(this);
    };

    Scene_Boot.prototype.start = function() {
        Scene_Base.prototype.start.call(this);
        SceneManager.goto(Scene_MkxpSmoke);
    };

    function Scene_MkxpSmoke() {
        this.initialize.apply(this, arguments);
    }

    Scene_MkxpSmoke.prototype = Object.create(Scene_Base.prototype);
    Scene_MkxpSmoke.prototype.constructor = Scene_MkxpSmoke;

    Scene_MkxpSmoke.prototype.create = function() {
        Scene_Base.prototype.create.call(this);

        this._background = new Sprite(new Bitmap(Graphics.width, Graphics.height));
        this._background.bitmap.fillAll('#0000ff');
        this.addChild(this._background);

        this._square = new Sprite(new Bitmap(100, 100));
        this._square.bitmap.fillAll('#ff0000');
        this._square.x = 50;
        this._square.y = 50;
        this.addChild(this._square);

        this._text = new Sprite(new Bitmap(300, 60));
        this._text.bitmap.fontSize = 40;
        this._text.bitmap.drawText('MV smoke', 0, 0, 300, 60);
        this._text.x = 50;
        this._text.y = 300;
        this.addChild(this._text);

        this._frames = 0;
    };

    Scene_MkxpSmoke.prototype.update = function() {
        Scene_Base.prototype.update.call(this);

        this._frames++;

        if (this._frames === 240)
            SceneManager.exit();

        if (this._frames !== 60)
            return;

        var text = this._text.bitmap;
        var textPixels = 0;
        for (var y = 0; y < text.height; y++)
            for (var x = 0; x < text.width; x++)
                if (text.getAlphaPixel(x, y) > 0)
                    textPixels++;

        var lines = [
            'background ' + this._background.bitmap.getPixel(10, 10),
            'square ' + this._square.bitmap.getPixel(50, 50),
            'screen ' + Graphics.width + 'x' + Graphics.height,
            'text_pixels ' + textPixels
        ];

        var dir = path.dirname(process.mainModule.filename);
        fs.writeFileSync(path.join(dir, 'result.txt'), lines.join('\n') + '\n');
    };
})();

#pragma once
#include <AudioOutput.h>
#include <math.h>

// Makes the watch's tiny speaker as loud as it can be without crackling.
// Sits between the MP3 decoder and the I2S output:
//   1. High-pass at 300 Hz: the speaker cannot play bass, but bass still eats
//      the headroom and is what distorts first.
//   2. Drive (SetGain) then a soft limiter: loud peaks are rounded off
//      smoothly instead of being chopped (hard clipping = the crackle).
class LoudOutput : public AudioOutput {
public:
    explicit LoudOutput(AudioOutput *sink) : sink(sink) {}

    bool SetRate(int hz) override
    {
        hertz = hz;
        design_highpass(300.0f, (float)hz);
        return sink->SetRate(hz);
    }
    bool SetBitsPerSample(int bits) override { return sink->SetBitsPerSample(bits); }
    bool SetChannels(int chan) override { return sink->SetChannels(chan); }
    bool SetGain(float f) override
    {
        drive = f;
        return true;
    }
    bool begin() override
    {
        pending = false;
        for (auto &s : state) s = {};
        return sink->begin();
    }
    bool stop() override { return sink->stop(); }
    void flush() override { sink->flush(); }

    // The decoder calls this again with the same sample when it returns false,
    // so a processed sample the sink refused is kept and resent, not re-filtered.
    bool ConsumeSample(int16_t sample[2]) override
    {
        if (!pending) {
            for (int ch = 0; ch < 2; ch++) out[ch] = process(ch, sample[ch]);
        }
        pending = !sink->ConsumeSample(out);
        return !pending;
    }

private:
    struct Biquad { float x1, x2, y1, y2; };

    AudioOutput *sink;
    float drive = 1.0f;
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    Biquad state[2] = {};
    int16_t out[2] = {0, 0};
    bool pending = false;

    // RBJ cookbook high-pass, Q = 0.707.
    void design_highpass(float cutoff, float rate)
    {
        float w0 = 2.0f * (float)M_PI * cutoff / rate;
        float alpha = sinf(w0) / (2.0f * 0.7071f);
        float c = cosf(w0);
        float a0 = 1.0f + alpha;
        b0 = (1.0f + c) / 2.0f / a0;
        b1 = -(1.0f + c) / a0;
        b2 = (1.0f + c) / 2.0f / a0;
        a1 = -2.0f * c / a0;
        a2 = (1.0f - alpha) / a0;
    }

    int16_t process(int ch, int16_t in)
    {
        Biquad &s = state[ch];
        float x = in / 32768.0f;
        float y = b0 * x + b1 * s.x1 + b2 * s.x2 - a1 * s.y1 - a2 * s.y2;
        s.x2 = s.x1; s.x1 = x;
        s.y2 = s.y1; s.y1 = y;

        // Soft limiter (rational tanh approximation): linear for small
        // signals, curves smoothly to +-1 instead of a hard clip.
        float v = y * drive;
        if (v > 3.0f) v = 3.0f;
        if (v < -3.0f) v = -3.0f;
        float limited = v * (27.0f + v * v) / (27.0f + 9.0f * v * v);
        return (int16_t)(limited * 32000.0f);
    }
};

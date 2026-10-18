/*
 * gen_train_wav.c - deterministic synthetic "music" generator for PGO training.
 *
 * Usage: gen_train_wav <out.wav> <rate> <channels> <bits:16|24|32f> <seconds> [seed]
 *
 * The signal mixes harmonic chords with vibrato, partially correlated stereo,
 * sharp kick/snare/hi-hat transients (short blocks), quiet passages, short
 * silences and a full-band noise section, so the encoder's psychoacoustics,
 * block switching, stereo decisions and bit allocation all get exercised.
 *
 * MIT License (same as the build scripts in this repository).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static uint32_t rng_state = 1;
static uint32_t rng(void) { rng_state = rng_state * 1664525u + 1013904223u; return rng_state; }
static double frand(void) { return (rng() >> 8) * (1.0 / 16777216.0); }        /* [0,1) */
static double nrand(void) { return frand() * 2.0 - 1.0; }                        /* [-1,1) */

static void put16(FILE *f, unsigned v) { fputc(v & 255, f); fputc((v >> 8) & 255, f); }
static void put32(FILE *f, uint32_t v) { put16(f, v & 0xFFFF); put16(f, v >> 16); }

#define NVOICE 6

int main(int argc, char **argv)
{
    if (argc < 6) {
        fprintf(stderr, "usage: %s out.wav rate channels bits(16|24|32f) seconds [seed]\n", argv[0]);
        return 2;
    }
    const char *out = argv[1];
    int rate = atoi(argv[2]);
    int ch = atoi(argv[3]);
    int is_float = strcmp(argv[4], "32f") == 0;
    int bits = is_float ? 32 : atoi(argv[4]);
    double secs = atof(argv[5]);
    rng_state = argc > 6 ? (uint32_t)strtoul(argv[6], NULL, 10) : 12345u;

    if (ch < 1 || ch > 2 || rate < 8000 || rate > 48000 || (!is_float && bits != 16 && bits != 24)) {
        fprintf(stderr, "unsupported parameters\n");
        return 2;
    }

    FILE *f = fopen(out, "wb");
    if (!f) { perror(out); return 1; }

    uint32_t nframes = (uint32_t)(secs * rate);
    int bps = bits / 8;
    uint32_t datasize = nframes * ch * bps;

    fwrite("RIFF", 1, 4, f); put32(f, 36 + datasize); fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f); put32(f, 16);
    put16(f, is_float ? 3 : 1); put16(f, ch); put32(f, rate);
    put32(f, rate * ch * bps); put16(f, ch * bps); put16(f, bits);
    fwrite("data", 1, 4, f); put32(f, datasize);

    /* musical state */
    double freq[NVOICE], phase[NVOICE][2], amp[NVOICE], pan[NVOICE];
    int nharm[NVOICE];
    double env[NVOICE];
    for (int v = 0; v < NVOICE; v++) { freq[v] = 0; amp[v] = 0; env[v] = 0; phase[v][0] = phase[v][1] = 0; pan[v] = 0.5; nharm[v] = 1; }

    const double scale[] = { 0, 2, 3, 5, 7, 8, 10 };   /* natural minor */
    double beat = 60.0 / (90 + (rng() % 60));          /* 90..150 bpm */
    uint32_t beat_len = (uint32_t)(beat * rate);
    double kick_ph = 0, kick_env = 0, kick_f = 0, snare_env = 0, hat_env = 0;
    double lp_l = 0, lp_r = 0, vib_ph = 0;
    double noise_l = 0, noise_r = 0;

    for (uint32_t n = 0; n < nframes; n++) {
        double t = (double)n / rate;
        double section = fmod(t, 40.0);                 /* 40 s structure loop */
        int quiet   = section >= 24.0 && section < 30.0;
        int silence = section >= 30.0 && section < 30.7;
        int noisy   = section >= 34.0 && section < 37.0;

        /* new chord every 2 beats */
        if (n % (beat_len * 2) == 0) {
            int root = (int)(rng() % 7);
            for (int v = 0; v < NVOICE; v++) {
                int deg = root + (v % 3) * 2;
                int oct = 2 + v / 2 + (int)(rng() % 2);
                double semis = scale[deg % 7] + 12.0 * (oct + deg / 7);
                freq[v] = 32.703 * pow(2.0, semis / 12.0); /* C1 based */
                amp[v] = 0.06 + 0.06 * frand();
                pan[v] = frand();
                nharm[v] = 1 + (int)(rng() % 12);
                env[v] = 1.0;
            }
        }
        /* drums */
        uint32_t pos = n % beat_len;
        if (pos == 0) { kick_env = 1.0; kick_f = 150; kick_ph = 0; }
        if (pos == beat_len / 2 && (n / beat_len) % 2) snare_env = 1.0;
        if (pos % (beat_len / 4) == 0) hat_env = 0.6 + 0.4 * frand();

        vib_ph += 2 * M_PI * 5.5 / rate;
        double vib = 1.0 + 0.004 * sin(vib_ph);

        double l = 0, r = 0;
        for (int v = 0; v < NVOICE; v++) {
            env[v] *= 0.99997;
            double s = 0;
            for (int h = 1; h <= nharm[v]; h++) {
                double fh = freq[v] * h * vib;
                if (fh > rate * 0.45) break;
                s += sin(phase[v][0] * h) / h;
            }
            phase[v][0] += 2 * M_PI * freq[v] * vib / rate;
            if (phase[v][0] > 2 * M_PI * 1000) phase[v][0] = fmod(phase[v][0], 2 * M_PI);
            s *= amp[v] * env[v];
            l += s * (1.0 - pan[v]);
            r += s * pan[v];
        }

        /* kick: pitch-dropping sine, sharp attack */
        kick_f = 45 + (kick_f - 45) * 0.9993;
        kick_ph += 2 * M_PI * kick_f / rate;
        kick_env *= 0.9996;
        double kick = sin(kick_ph) * kick_env * 0.5;

        /* snare + hat: filtered noise bursts */
        snare_env *= 0.9990;
        hat_env *= 0.9960;
        double wn_l = nrand(), wn_r = nrand();
        noise_l = 0.6 * noise_l + 0.4 * wn_l;
        noise_r = 0.6 * noise_r + 0.4 * wn_r;
        double hp_l = wn_l - noise_l, hp_r = wn_r - noise_r; /* crude highpass */

        l += kick + snare_env * 0.25 * noise_l + hat_env * 0.12 * hp_l;
        r += kick + snare_env * 0.25 * noise_r + hat_env * 0.12 * hp_r;

        if (noisy) { l += 0.3 * nrand(); r += 0.3 * nrand(); }
        if (quiet) { l *= 0.02; r *= 0.02; }
        if (silence) { l = r = 0; }

        /* gentle smoothing to avoid pure digital edges, keep some HF */
        lp_l = 0.15 * lp_l + 0.85 * l;
        lp_r = 0.15 * lp_r + 0.85 * r;
        l = lp_l; r = lp_r;

        double outs[2] = { l, r };
        if (ch == 1) outs[0] = 0.5 * (l + r);

        for (int c = 0; c < ch; c++) {
            double x = outs[c];
            if (x > 0.999) x = 0.999;
            if (x < -0.999) x = -0.999;
            if (is_float) {
                float fl = (float)x;
                uint32_t u; memcpy(&u, &fl, 4); put32(f, u);
            } else if (bits == 16) {
                int v = (int)lrint(x * 32767.0 + (frand() - frand()));  /* TPDF dither */
                if (v > 32767) v = 32767;
                if (v < -32768) v = -32768;
                put16(f, (unsigned)(v & 0xFFFF));
            } else {
                int32_t v = (int32_t)lrint(x * 8388607.0);
                fputc(v & 255, f); fputc((v >> 8) & 255, f); fputc((v >> 16) & 255, f);
            }
        }
    }
    fclose(f);
    return 0;
}

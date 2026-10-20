// App entry point for a macroquad build packaged as a cdylib: miniquad's Java
// side calls `quad_main`, and `#[macroquad::main]` generates the `fn main()`
// that runs the game. cargo-quad-apk injects this shim for bin targets; here
// it is written by hand.

use macroquad::prelude::*;

const MAX_PARTICLES: usize = 500;
const SPARKS_PER_POINT: usize = 5;

struct Particle {
    pos: Vec2,
    vel: Vec2,
    color: Color,
    life: f32, // 1.0 (nova) -> 0.0 (morta)
}

impl Particle {
    fn emitted_at(pos: Vec2) -> Self {
        let angle = rand::gen_range(0.0f32, std::f32::consts::TAU);
        let speed = rand::gen_range(20.0f32, 220.0);

        Self {
            pos,
            vel: vec2(angle.cos() * speed, angle.sin() * speed - 60.0),
            color: Color::new(
                rand::gen_range(0.25f32, 1.0),
                rand::gen_range(0.25f32, 1.0),
                rand::gen_range(0.25f32, 1.0),
                1.0,
            ),
            life: 1.0,
        }
    }
}

#[macroquad::main("Macroquad Termux Android")]
async fn main() {
    // quad-rand starts with a zeroed state; without a seed every run yields the
    // same sequence (cosmetic here, but avoids identical particles each launch).
    rand::srand((get_time() * 1000.0) as u64);

    let mut particles: Vec<Particle> = Vec::with_capacity(MAX_PARTICLES);
    let mut next = 0;

    loop {
        // Without the clamp a long frame (rotation, app backgrounded) advances
        // every particle at once and they all expire in the same frame.
        let dt = get_frame_time().min(1.0 / 30.0);

        // Android reports touches, desktop reports the mouse: the same loop
        // works for testing on the host.
        let mut points: Vec<Vec2> = touches().into_iter().map(|t| t.position).collect();
        if is_mouse_button_down(MouseButton::Left) {
            let (mx, my) = mouse_position();
            points.push(vec2(mx, my));
        }

        for point in &points {
            for _ in 0..SPARKS_PER_POINT {
                let particle = Particle::emitted_at(*point);
                // Reuses an in-place ring buffer: no allocation while running.
                if particles.len() < MAX_PARTICLES {
                    particles.push(particle);
                } else {
                    particles[next] = particle;
                    next = (next + 1) % MAX_PARTICLES;
                }
            }
        }

        clear_background(Color::new(0.04, 0.05, 0.08, 1.0));

        for particle in &mut particles {
            if particle.life <= 0.0 {
                continue;
            }

            particle.life -= dt * 0.8;
            particle.pos += particle.vel * dt;
            particle.vel *= 0.985;

            let life = particle.life.max(0.0);
            let mut color = particle.color;
            color.a = life;

            draw_circle(particle.pos.x, particle.pos.y, 6.0 * life, color);
        }

        draw_text(
            format!("FPS {} | particulas {}", get_fps(), particles.len()),
            16.0,
            32.0,
            28.0,
            WHITE,
        );

        next_frame().await;
    }
}

// A cdylib has no entry point: the JNI call from QuadNative.activityOnCreate
// lands on this symbol, which runs the main above.
#[unsafe(no_mangle)]
pub extern "C" fn quad_main() {
    main();
}

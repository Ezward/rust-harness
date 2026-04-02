fn run() -> String {
    "Hello, world!".to_string()
}

#[cfg(not(coverage))]
fn main() {
    println!("{}", run());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_run() {
        assert_eq!(run(), "Hello, world!");
    }
}

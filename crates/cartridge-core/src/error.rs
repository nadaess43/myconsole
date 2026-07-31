use thiserror::Error;

#[derive(Error, Debug)]
pub enum CoreError {
    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("validation error: {0}")]
    Validation(String),

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("UUID error: {0}")]
    Uuid(#[from] uuid::Error),
}

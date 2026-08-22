-- Factory sessions could have left conversation memory behind. Remove it so
-- retired factory instructions cannot be retrieved by the active runtime.
DELETE FROM memory_sessions
WHERE session_id LIKE 'factory-%';

DELETE FROM chat_sessions
WHERE session_id LIKE 'factory-%';

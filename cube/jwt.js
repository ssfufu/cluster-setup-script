const jwt = require('jsonwebtoken');

const cubejsToken = jwt.sign({}, 'YOUR_CUBEJS_SECRET', { expiresIn: '30d' });
console.log(cubejsToken);
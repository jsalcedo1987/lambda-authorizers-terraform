exports.handler = async (event,context) => {
  const response = {
    statusCode: 200,
    body: event,
    context: context
  };
  return response;
};
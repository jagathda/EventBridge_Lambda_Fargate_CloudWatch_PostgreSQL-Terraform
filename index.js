const { ECSClient, RunTaskCommand } = require('@aws-sdk/client-ecs');

exports.handler = async (event) => {
  const ecs = new ECSClient();
  const params = {
    cluster: process.env.CLUSTER_NAME,
    taskDefinition: process.env.TASK_DEFINITION,
    launchType: 'FARGATE',
    networkConfiguration: {
      awsvpcConfiguration: {
        subnets: [process.env.SUBNET_1, process.env.SUBNET_2],
        securityGroups: [process.env.SECURITY_GROUP],
        assignPublicIp: 'DISABLED',
      },
    },
    overrides: {
      containerOverrides: [{
        name: 'my-container',
        environment: [
          { name: 'EVENT_PAYLOAD', value: JSON.stringify(event.detail) },
          { name: 'EVENT_TYPE', value: event['detail-type'] || 'Unknown' }
        ],
      }],
    },
  };
  try {
    const data = await ecs.send(new RunTaskCommand(params));
    console.log("ECS Task started successfully:", JSON.stringify(data, null, 2));
  } catch (err) {
    console.error("Failed to start ECS task:", err);
  }
};

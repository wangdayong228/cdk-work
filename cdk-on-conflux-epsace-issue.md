## cdk

We are currently experimenting with using CDK to deploy a zkRollup chain on Conflux eSpace.

Conflux eSpace is an Ethereum-compatible Layer 1 chain.

At the moment, we’re using kurtosis-cdk v0.2.29, and after performing some RPC compatibility adaptations, we were able to successfully launch a zkRollup chain on eSpace.

Note: We have not enabled the agglayer module in this setup.

However, we’ve encountered an issue: after running the L2 for about a week, the last sequenced/verified batch number became stuck and stopped updating.

We’re having difficulty pinpointing the root cause of the issue.
So we’d like to ask:

Have you experienced a similar problem before?

Do you have any suggestions or best practices on how to debug and resolve this?

Any insights would be greatly appreciated. Thanks in advance!

from __future__ import annotations

import os
from glob import glob

from setuptools import find_packages, setup

package_name = "pocketsensor_ros"

setup(
    name=package_name,
    version="0.1.0",
    packages=find_packages(exclude=["test"]),
    data_files=[
        ("share/ament_index/resource_index/packages", ["resource/" + package_name]),
        ("share/" + package_name, ["package.xml"]),
        (os.path.join("share", package_name, "launch"), glob("launch/*.py")),
        (os.path.join("share", package_name, "urdf"), glob("urdf/*")),
    ],
    install_requires=["setuptools"],
    zip_safe=True,
    maintainer="pocketsensor",
    maintainer_email="pocketsensor@localhost",
    description="Relay pocketsensor CDR streams onto ROS 2 topics.",
    license="Apache-2.0",
    entry_points={
        "console_scripts": [
            "relay = pocketsensor_ros.relay:main",
        ],
    },
)
